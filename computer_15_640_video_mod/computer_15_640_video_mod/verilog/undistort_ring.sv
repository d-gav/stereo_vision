// =============================================================================
// undistort_ring
//
// Staging ring buffer for the radial-undistortion pass that runs alongside
// PHASE_FILL in DE1_SoC_Computer.v. Holds RING_DEPTH = K+1 destination rows
// in flight while older rows are committed back to the main on-chip SRAM.
//
// Why this exists: the undistortion pass overwrites the main SRAM in place
// (no second 200 KB buffer fits on the device). Each destination row r reads
// raw source pixels from rows in [r-K .. r+K]; if we wrote dst row r back
// to the SRAM before processing dst row r+K, the raw pixels still needed by
// later destinations would be destroyed. The ring delays the writeback by
// K rows so that by the time row r is committed, no later destination still
// needs row r as a source.
//
// RING_DEPTH must be >= 1 + max |src_y - dst_y| of the radial mapper LUT.
// For mild lenses K = 8..12 typically suffices; bump the parameter up if
// the mapper produces larger Y shifts. Each slot is one M10K (256 x 32).
//
// Write port: byte-granular (matches the per-pixel produce rate of the
// mapper-driven FILL loop).
// Read port:  32-bit word (matches the s2-side write back to the main SRAM).
// 1-cycle read latency on rd_data.
// =============================================================================

`default_nettype none

module undistort_ring #(
    parameter int RING_DEPTH = 13   // K = RING_DEPTH - 1
) (
    input  wire        clk,

    // Write port: drop a single byte into a slot at a byte column.
    input  wire [3:0]  wr_slot,        // 0..RING_DEPTH-1
    input  wire [9:0]  wr_byte_col,    // 0..1023
    input  wire        wr_en,
    input  wire [7:0]  wr_data,

    // Read port: 32-bit word out of the named slot.
    input  wire [3:0]  rd_slot,        // 0..RING_DEPTH-1
    input  wire [7:0]  rd_word,        // 0..255
    output reg  [31:0] rd_data
);

    wire [7:0]  wr_word_idx  = wr_byte_col[9:2];
    wire [1:0]  wr_byte_lane = wr_byte_col[1:0];
    wire [31:0] wr_data_x4   = {4{wr_data}};

    wire [31:0] slot_rdata [RING_DEPTH-1:0];

    // Per-slot M10K. Reusing stereo_onchip_ram_row gives us a known-good
    // SDP altsyncram (32-bit width, byte-enabled write, 1-cycle read).
    genvar s;
    generate
        for (s = 0; s < RING_DEPTH; s = s + 1) begin : g_slot
            wire is_wr = (wr_slot == s[3:0]) & wr_en;
            wire [3:0] be_oh = (4'b0001 << wr_byte_lane) & {4{is_wr}};

            stereo_onchip_ram_row u_row (
                .clk    (clk),
                .a_addr (wr_word_idx),
                .a_be   (be_oh),
                .a_wdata(wr_data_x4),
                .b_addr (rd_word),
                .b_rdata(slot_rdata[s])
            );
        end
    endgenerate

    // M10K read latency is one cycle, so register the slot index used for
    // the output mux to align with the registered b_addr.
    reg [3:0] rd_slot_q;
    always @(posedge clk) begin
        rd_slot_q <= rd_slot;
    end

    integer i;
    always @(*) begin
        rd_data = 32'h0;
        for (i = 0; i < RING_DEPTH; i = i + 1) begin
            if (i[3:0] == rd_slot_q) rd_data = slot_rdata[i];
        end
    end

endmodule

`default_nettype wire
