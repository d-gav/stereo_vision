// =============================================================================
// stereo_onchip_ram
//
// Custom row-banked replacement for the Qsys altera_avalon_onchip_memory2 IP
// "Onchip_SRAM" in Computer_System.qsys. Drop-in compatible at the Avalon
// boundary: same s1 (8-bit) and s2 (32-bit) slave ports, same 1-cycle read
// latency, same 200 KB capacity (200 rows x 1024 bytes/row stride).
//
// What it adds: an extra "side-door" conduit (sad_*) that exposes port B of
// each row's M10K so the SAD engine can read one byte from EVERY row in
// parallel each cycle, eliminating the EBAB read-and-copy that today moves
// pixels from Onchip_SRAM into stereo_bram_bank.v.
//
// Memory layout (matches existing AUTO_VIDEO_IN_DMA_MASTER_ADDRESS_MAP):
//   total_bytes = N_ROWS * ROW_BYTES                    (200*1024 = 204800)
//   row_index   = byte_addr[17:10]                      (0..199)
//   col_index   = byte_addr[ 9: 0]                      (0..1023, byte)
//
// Per-row storage: one M10K configured 256x32, simple dual-port (DUAL_PORT
// in altsyncram terms). Port A is write-only with 4-byte enables and serves
// both Avalon slaves' write paths (s1 8-bit byte writes from Video-In DMA
// and s2 32-bit writes from HPS, with s1 priority on the unlikely
// collision). Port B is read-only and serves all three read paths: s1
// reads, s2 reads, and the SAD parallel read conduit (priority s1 > s2 >
// SAD per row). True dual-port M10K on Cyclone V caps width at 16 bits and
// would force 2 M10Ks per row (200x2 = 400, exceeds the 397 available);
// SDP supports the full 32-bit width in one M10K (200 total).
//
// SAD and Avalon-read sharing is safe in this system because capture
// (DMA writes), compute (SAD reads), and VGA / HPS readback are
// workflow-separated phases that do not overlap. If s2 reads do happen
// during a SAD cycle, only the addressed row's sad_rdata lane is stale
// for that one cycle; other rows are unaffected.
//
// altsyncram is instantiated directly rather than relying on inference:
// Quartus 18.1 Standard's byte-enabled dual-port RAM inference is
// unreliable (cycles through 276010 / 276003 / 10028 across blocking-vs-
// non-blocking and packed-vs-flat array variations).
// =============================================================================

`default_nettype none

// -----------------------------------------------------------------------------
// Per-row M10K: 256 deep x 32 bits wide, byte-enabled, simple dual-port.
// Port A is write-only (with byte enables); port B is read-only. This fits
// in a single M10K per row on Cyclone V — true-dual-port M10K caps width at
// 16 bits, which would force 2 M10Ks per row and overflow the device (200
// rows x 2 = 400 > 397 available). Simple dual-port supports the full 32-bit
// width in one M10K, so 200 rows = 200 M10Ks.
//
// Read latency is 1 cycle (address registered into M10K, q_b unregistered).
// -----------------------------------------------------------------------------
module stereo_onchip_ram_row (
    input  wire        clk,

    // Port A: write-only
    input  wire [7:0]  a_addr,
    input  wire [3:0]  a_be,
    input  wire [31:0] a_wdata,

    // Port B: read-only
    input  wire [7:0]  b_addr,
    output wire [31:0] b_rdata
);

    altsyncram #(
        .operation_mode                    ("DUAL_PORT"),
        .intended_device_family            ("Cyclone V"),
        .ram_block_type                    ("M10K"),
        .width_a                           (32),
        .widthad_a                         (8),
        .numwords_a                        (256),
        .width_b                           (32),
        .widthad_b                         (8),
        .numwords_b                        (256),
        .width_byteena_a                   (4),
        .byte_size                         (8),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .outdata_reg_b                     ("UNREGISTERED"),
        .indata_aclr_a                     ("NONE"),
        .wrcontrol_aclr_a                  ("NONE"),
        .address_aclr_a                    ("NONE"),
        .byteena_aclr_a                    ("NONE"),
        .address_aclr_b                    ("NONE"),
        .outdata_aclr_b                    ("NONE"),
        .clock_enable_input_a              ("BYPASS"),
        .clock_enable_input_b              ("BYPASS"),
        .clock_enable_output_b             ("BYPASS"),
        .power_up_uninitialized            ("FALSE"),
        .lpm_type                          ("altsyncram")
    ) u_m10k (
        .clock0        (clk),
        .clock1        (clk),
        .clocken0      (1'b1),
        .clocken1      (1'b1),
        .aclr0         (1'b0),
        .aclr1         (1'b0),
        .address_a     (a_addr),
        .byteena_a     (a_be),
        .data_a        (a_wdata),
        .wren_a        (|a_be),
        .addressstall_a(1'b0),
        .address_b     (b_addr),
        .rden_b        (1'b1),
        .addressstall_b(1'b0),
        .q_b           (b_rdata)
    );

endmodule

// -----------------------------------------------------------------------------
// Top: row-banked Avalon-MM on-chip memory + parallel SAD read conduit.
// -----------------------------------------------------------------------------
module stereo_onchip_ram #(
    parameter int N_ROWS    = 200,
    parameter int ROW_BYTES = 1024
) (
    input  wire                       clk,
    input  wire                       reset,    // unused; M10K contents power-up to 0

    // ---------------------------------------------------------------------
    // Avalon-MM slave s1: 8-bit, byte-addressable.
    // Matches Onchip_SRAM.s1 in Computer_System.qsys (dataWidth=8,
    // slave1Latency=1). Connected by the Qsys interconnect to
    // Video_In_Subsystem.video_in_dma_master.
    // ---------------------------------------------------------------------
    input  wire [17:0]                s1_address,      // byte address into 200 KB
    input  wire                       s1_chipselect,
    input  wire                       s1_clken,        // accepted for compat; ignored
    input  wire                       s1_write,
    input  wire                       s1_read,
    input  wire [7:0]                 s1_writedata,
    output reg  [7:0]                 s1_readdata,

    // ---------------------------------------------------------------------
    // Avalon-MM slave s2: 32-bit, word-addressable.
    // Matches Onchip_SRAM.s2 (dataWidth2=32, slave2Latency=1). Connected to
    // ARM_A9_HPS.h2f_axi_master and EBAB_video_in.avalon_master.
    // ---------------------------------------------------------------------
    input  wire [15:0]                s2_address,      // word address (200KB/4 = 51200)
    input  wire                       s2_chipselect,
    input  wire                       s2_clken,        // accepted for compat; ignored
    input  wire                       s2_write,
    input  wire                       s2_read,
    input  wire [3:0]                 s2_byteenable,
    input  wire [31:0]                s2_writedata,
    output reg  [31:0]                s2_readdata,

    // ---------------------------------------------------------------------
    // Private SAD read conduit. One byte per row in parallel, latency 1.
    // sad_col is a byte column 0..ROW_BYTES-1 within each row.
    // ---------------------------------------------------------------------
    input  wire                       sad_re,          // accepted for compat; M10Ks read every cycle
    input  wire [9:0]                 sad_col,
    output reg  [N_ROWS-1:0][7:0]     sad_rdata,

    // ---------------------------------------------------------------------
    // Private control conduit: when high, s1 writes are silently dropped.
    // Used by DE1_SoC_Computer.v to freeze the SRAM contents during the
    // PHASE_DRAIN + PHASE_COMPUTE window so that the undistorted bytes
    // committed by drain are not immediately overwritten by the autonomous
    // Video-In DMA before SAD can read them. The DMA's address counter
    // still advances normally; the dropped bytes show up as gaps that get
    // refilled on the next FILL pass.
    // ---------------------------------------------------------------------
    input  wire                       s1_write_lock
);

    // ---------------------------------------------------------------------
    // Address decoding. Row index occupies the upper bits, byte/word column
    // the lower bits. We use 8-bit row index because $clog2(200)=8 and that
    // matches the byte-address layout Qsys gives us (s1_address[17:10] when
    // ROW_BYTES=1024).
    // ---------------------------------------------------------------------
    wire [7:0] s1_row_idx   = s1_address[17:10];
    wire [7:0] s1_word_idx  = s1_address[ 9: 2];
    wire [1:0] s1_byte_lane = s1_address[ 1: 0];

    wire [7:0] s2_row_idx   = s2_address[15: 8];
    wire [7:0] s2_word_idx  = s2_address[ 7: 0];

    wire [7:0] sad_word_idx  = sad_col[9:2];
    wire [1:0] sad_byte_lane = sad_col[1:0];

    // Per-row read bus (one shared 32-bit read port per row).
    wire [31:0] rowB_rdata [N_ROWS];

    // ---------------------------------------------------------------------
    // Pipeline registers for the read-data muxes. The M10K registers its
    // address inputs, so the row index and byte lane used to mux outputs
    // must be the values that were valid one cycle earlier.
    // ---------------------------------------------------------------------
    reg [7:0] s1_row_idx_q;
    reg [1:0] s1_byte_lane_q;
    reg [7:0] s2_row_idx_q;
    reg [1:0] sad_byte_lane_q;

    always @(posedge clk) begin
        s1_row_idx_q    <= s1_row_idx;
        s1_byte_lane_q  <= s1_byte_lane;
        s2_row_idx_q    <= s2_row_idx;
        sad_byte_lane_q <= sad_byte_lane;
    end

    // ---------------------------------------------------------------------
    // Per-row instantiation. Each row is an SDP M10K. Port A is write-only,
    // shared between s1 (Video-In DMA byte writes) and s2 (PHASE_DRAIN
    // 32-bit writes). Port B is read-only, shared between s1 reads, s2 reads,
    // and the SAD parallel read conduit (priority s1 > s2 > SAD per row).
    //
    // Write-port arbitration is GLOBAL, not per-row, to save ~3.2k ALMs that
    // would otherwise go into a 32-bit a_wdata mux replicated 200 times.
    // Instead, a single global arbiter computes the winning master's
    // (a_addr, a_wdata, a_be), broadcasts to all rows, and per-row logic
    // just gates `a_be` by a 1-bit `row_active`. The trade-off is that if
    // s1 and s2 fire writes on the same cycle to *different* rows, only
    // the priority winner's row gets written; the other write is dropped.
    // Priority is s2-wins because in this system s2 writes only happen
    // during PHASE_DRAIN (a tight ~3 ms window) and dropping drain writes
    // would corrupt the undistorted SRAM directly, whereas dropping a few
    // s1 (DMA) bytes during that window only adds a small noise floor to
    // the next captured frame's input.
    //
    // SAD/Avalon read sharing on port B is unchanged: when s2 reads row r,
    // that row's b_addr is hijacked to s2_word_idx for one cycle and SAD's
    // output for row r is stale; safe because workflow phases (capture /
    // compute / readback) don't overlap.
    // ---------------------------------------------------------------------

    // Global write inputs. s1 writes 1 byte per transaction; s2 writes a
    // 32-bit word with its own byteenable. s1_write_lock forces s1 writes
    // to be ignored without affecting Avalon handshaking (no waitrequest),
    // which is the lightweight way to freeze the SRAM during the drain +
    // compute window without modifying Qsys or stalling the DMA upstream.
    wire        any_s1_w        = s1_chipselect & s1_write & ~s1_write_lock;
    wire        any_s2_w        = s2_chipselect & s2_write;
    wire [3:0]  s1_be_oh_global = (4'b0001 << s1_byte_lane);
    wire [31:0] s1_wdata_x4     = {4{s1_writedata}};

    wire [7:0]  global_a_addr   = any_s2_w ? s2_word_idx  : s1_word_idx;
    wire [31:0] global_a_wdata  = any_s2_w ? s2_writedata : s1_wdata_x4;
    wire [3:0]  global_a_be_in  = any_s2_w ? s2_byteenable : s1_be_oh_global;

    genvar r;
    generate
        for (r = 0; r < N_ROWS; r = r + 1) begin : g_row
            // Per-row row index match for whichever master is winning the
            // write arbitration this cycle. Reads keep their independent
            // matches so SAD continues reading even when only one Avalon
            // master is active.
            wire s1_match   = s1_chipselect & (s1_row_idx == r[7:0]);
            wire s2_match   = s2_chipselect & (s2_row_idx == r[7:0]);
            wire s1_r_active = s1_match & s1_read;
            wire s2_r_active = s2_match & s2_read;

            // Row receives the global write only if it is the addressed row
            // of the priority-winning master.
            wire row_active = any_s2_w ? s2_match
                            : any_s1_w ? s1_match
                                       : 1'b0;
            wire [3:0] a_be = global_a_be_in & {4{row_active}};

            // ---- Port B (reads): s1 read > s2 read > SAD default. ----
            wire [7:0] b_addr = s1_r_active ? s1_word_idx
                              : s2_r_active ? s2_word_idx
                                            : sad_word_idx;

            stereo_onchip_ram_row u_row (
                .clk    (clk),
                .a_addr (global_a_addr),
                .a_be   (a_be),
                .a_wdata(global_a_wdata),
                .b_addr (b_addr),
                .b_rdata(rowB_rdata[r])
            );

            // SAD output for this row: pick the byte lane out of the 32-bit
            // port-B read using the registered byte lane.
            always @(*) begin
                case (sad_byte_lane_q)
                    2'd0:    sad_rdata[r] = rowB_rdata[r][ 7: 0];
                    2'd1:    sad_rdata[r] = rowB_rdata[r][15: 8];
                    2'd2:    sad_rdata[r] = rowB_rdata[r][23:16];
                    default: sad_rdata[r] = rowB_rdata[r][31:24];
                endcase
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // s2 readdata: 2-stage pipelined 200:1 mux.
    //
    // The 200-way 32-bit fanout from rowB_rdata into a single combinational
    // mux is the worst routing hot-spot in the design — Quartus's P&R
    // either failed or took forever to converge with the original flat
    // implementation. We break it into:
    //
    //   Stage 1 (combinational): for each group of GROUP_SIZE rows, do a
    //                            small within-group select using the low
    //                            4 bits of s2_row_idx_q.
    //   Pipeline (1 cycle):      register the per-group outputs and the
    //                            high 4 bits of s2_row_idx_q.
    //   Stage 2 (combinational): select among groups using the registered
    //                            high bits.
    //
    // Each stage's combinational path is short (16:1 or 13:1 max), and the
    // 200 long M10K outputs only need to reach the local stage-1 mux of
    // their own group. Routing complexity drops by ~10x at the cost of one
    // extra cycle of s2 read latency. stereo_onchip_ram_hw.tcl now declares
    // s2.readLatency = 2 to match.
    // ---------------------------------------------------------------------
    localparam int GROUP_SIZE = 16;
    localparam int N_GROUPS   = (N_ROWS + GROUP_SIZE - 1) / GROUP_SIZE;
    localparam int GRP_SEL_W  = (N_GROUPS <= 1) ? 1 : $clog2(N_GROUPS);

    reg [31:0]          grp_pick_comb [N_GROUPS-1:0];
    reg [31:0]          grp_pick_q    [N_GROUPS-1:0];
    reg [GRP_SEL_W-1:0] s2_grp_idx_qq;

    // Stage 1: per-group within-group mux (combinational).
    integer ig1, ir1;
    always @(*) begin
        for (ig1 = 0; ig1 < N_GROUPS; ig1 = ig1 + 1) begin
            grp_pick_comb[ig1] = 32'h0;
            for (ir1 = 0; ir1 < GROUP_SIZE; ir1 = ir1 + 1) begin
                if (ig1 * GROUP_SIZE + ir1 < N_ROWS) begin
                    if (ir1[3:0] == s2_row_idx_q[3:0]) begin
                        grp_pick_comb[ig1] = rowB_rdata[ig1 * GROUP_SIZE + ir1];
                    end
                end
            end
        end
    end

    // Pipeline: register the group outputs and the high-bit selector.
    integer ig2;
    always @(posedge clk) begin
        for (ig2 = 0; ig2 < N_GROUPS; ig2 = ig2 + 1) begin
            grp_pick_q[ig2] <= grp_pick_comb[ig2];
        end
        s2_grp_idx_qq <= s2_row_idx_q[7:4];
    end

    // Stage 2: group select (combinational).
    integer ig3;
    always @(*) begin
        s2_readdata = 32'h0;
        for (ig3 = 0; ig3 < N_GROUPS; ig3 = ig3 + 1) begin
            if (ig3[GRP_SEL_W-1:0] == s2_grp_idx_qq) begin
                s2_readdata = grp_pick_q[ig3];
            end
        end
    end

    // ---------------------------------------------------------------------
    // s1 readdata: pick the row, then the byte lane.
    // ---------------------------------------------------------------------
    integer i_s1;
    reg [31:0] s1_word;
    always @(*) begin
        s1_word = 32'h0;
        for (i_s1 = 0; i_s1 < N_ROWS; i_s1 = i_s1 + 1) begin
            if (i_s1[7:0] == s1_row_idx_q) s1_word = rowB_rdata[i_s1];
        end
    end
    always @(*) begin
        case (s1_byte_lane_q)
            2'd0:    s1_readdata = s1_word[ 7: 0];
            2'd1:    s1_readdata = s1_word[15: 8];
            2'd2:    s1_readdata = s1_word[23:16];
            default: s1_readdata = s1_word[31:24];
        endcase
    end

endmodule

`default_nettype wire
