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
// Per-row storage: one M10K configured 256x32 with per-byte enables, true
// dual-port. Port A is 32-bit and serves the Avalon s2 slave (HPS h2f_axi
// and the FPGA-side EBAB master, after Qsys interconnect arbitration). Port
// B is also 32-bit and is shared between the s1 8-bit Avalon slave (Video-In
// DMA writes) and the SAD parallel read port. Capture and compute phases are
// temporally exclusive in this system (DMA writes the frame, then SAD reads
// it), so this sharing is safe; if s1 happens to hit during a SAD cycle,
// only the addressed row's sad_rdata lane is invalid for that cycle.
//
// Coding style follows the Altera Quartus Prime Pro Edition User Guide:
// Design Recommendations (UG-20131) Examples 16 (true dual-port single
// clock) + 23 (byte-enabled simple dual-port), combined into a byte-enabled
// true dual-port template that Quartus infers as a single M10K per row.
// Two always blocks both blocking-write the shared `mem` variable, which is
// the recognized inference pattern for TDP RAM.
// =============================================================================

`default_nettype none

// -----------------------------------------------------------------------------
// Per-row M10K: 256 deep x 32 bits wide, byte-enabled, true dual-port.
// Each port can independently read or partially write (per byte lane). Read
// data is registered, giving the 1-cycle latency the Qsys interconnect and
// the existing mem_block_intf both expect.
// -----------------------------------------------------------------------------
module stereo_onchip_ram_row (
    input  wire        clk,

    // Port A
    input  wire [7:0]  a_addr,        // word index 0..255
    input  wire [3:0]  a_be,          // per-byte write enable; 0 => read-only
    input  wire [31:0] a_wdata,
    output reg  [31:0] a_rdata,

    // Port B
    input  wire [7:0]  b_addr,
    input  wire [3:0]  b_be,
    input  wire [31:0] b_wdata,
    output reg  [31:0] b_rdata
);

    // Packed byte lanes inside each word so Quartus understands the
    // byte-enable structure (UG-20131 Example 23).
    (* ramstyle = "M10K" *) reg [3:0][7:0] mem [0:255];

    // Port A: blocking writes to the shared memory, non-blocking registered
    // read. Combined with the matching block below this is the byte-enabled
    // TDP inference pattern.
    always @(posedge clk) begin
        if (a_be[0]) mem[a_addr][0] = a_wdata[ 7: 0];
        if (a_be[1]) mem[a_addr][1] = a_wdata[15: 8];
        if (a_be[2]) mem[a_addr][2] = a_wdata[23:16];
        if (a_be[3]) mem[a_addr][3] = a_wdata[31:24];
        a_rdata <= mem[a_addr];
    end

    // Port B
    always @(posedge clk) begin
        if (b_be[0]) mem[b_addr][0] = b_wdata[ 7: 0];
        if (b_be[1]) mem[b_addr][1] = b_wdata[15: 8];
        if (b_be[2]) mem[b_addr][2] = b_wdata[23:16];
        if (b_be[3]) mem[b_addr][3] = b_wdata[31:24];
        b_rdata <= mem[b_addr];
    end

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
    output reg  [N_ROWS-1:0][7:0]     sad_rdata
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

    // Per-row read buses
    wire [31:0] rowA_rdata [N_ROWS];   // read out of port A (s2 path)
    wire [31:0] rowB_rdata [N_ROWS];   // read out of port B (s1 / SAD path)

    // ---------------------------------------------------------------------
    // Pipeline registers for the read-data muxes. The M10K registers its
    // output, so the row index, byte lane, and read-strobe used to mux that
    // output must be the values that were valid one cycle earlier.
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
    // Per-row instantiation. Each row gets its own M10K. Port A is dedicated
    // to s2, port B is shared between s1 (one row at a time) and SAD (all
    // rows in parallel) -- s1 wins for the addressed row when both are
    // active, which is fine because in this system capture (s1) and compute
    // (SAD) phases do not overlap.
    // ---------------------------------------------------------------------
    genvar r;
    generate
        for (r = 0; r < N_ROWS; r = r + 1) begin : g_row
            // ---- Port A: s2 32-bit ----
            wire        a_match = s2_chipselect & (s2_row_idx == r[7:0]);
            wire [3:0]  a_be    = (a_match & s2_write) ? s2_byteenable : 4'b0000;

            // ---- Port B: s1 8-bit OR SAD read ----
            wire        s1_match    = s1_chipselect & (s1_row_idx == r[7:0]);
            wire        s1_active   = s1_match & (s1_write | s1_read);
            // s1 8-bit write -> one-hot byte enable based on s1_address[1:0]
            wire [3:0]  s1_be_oh    = (4'b0001 << s1_byte_lane) & {4{s1_match & s1_write}};
            // Replicate the 8-bit write data across all four lanes; only the
            // enabled lane will actually be written.
            wire [31:0] s1_wdata_x4 = {4{s1_writedata}};
            // Address mux: when s1 is touching this row, port B serves s1;
            // otherwise it serves SAD. (s1 reads also win, since they share
            // the s1_active gate.)
            wire [7:0]  b_addr      = s1_active ? s1_word_idx : sad_word_idx;

            stereo_onchip_ram_row u_row (
                .clk    (clk),
                .a_addr (s2_word_idx),
                .a_be   (a_be),
                .a_wdata(s2_writedata),
                .a_rdata(rowA_rdata[r]),
                .b_addr (b_addr),
                .b_be   (s1_be_oh),
                .b_wdata(s1_wdata_x4),
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
    // s2 readdata: select the row whose port-A read is valid this cycle.
    // ---------------------------------------------------------------------
    integer i_s2;
    always @(*) begin
        s2_readdata = 32'h0;
        for (i_s2 = 0; i_s2 < N_ROWS; i_s2 = i_s2 + 1) begin
            if (i_s2[7:0] == s2_row_idx_q) s2_readdata = rowA_rdata[i_s2];
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
