# =============================================================================
# stereo_onchip_ram_hw.tcl
#
# Qsys / Platform Designer component description for stereo_onchip_ram, the
# row-banked drop-in replacement for the altera_avalon_onchip_memory2 IP
# "Onchip_SRAM" inside Computer_System.qsys.
#
# Exposes:
#   * Avalon-MM slave  s1       : 8-bit  byte-addressable, latency 1, writable
#   * Avalon-MM slave  s2       : 32-bit word-addressable, byte-enabled,
#                                  latency 1, writable
#   * Conduit          sad_port : private parallel-read side-door into port B
#                                  of every row's M10K (sad_re, sad_col, and
#                                  a flat sad_rdata bus = N_ROWS * 8 bits)
#
# Qsys auto-discovers any *_hw.tcl in the project's IP search path, so just
# placing this file next to stereo_onchip_ram.sv in
# computer_15_640_video_mod/verilog/ is enough -- the new component shows up
# in the IP Catalog under the group below.
# =============================================================================

package require -exact qsys 14.0

# -----------------------------------------------------------------------------
# Module description
# -----------------------------------------------------------------------------
set_module_property NAME                    stereo_onchip_ram
set_module_property DISPLAY_NAME            "Stereo On-Chip RAM (row-banked)"
set_module_property VERSION                 1.0
set_module_property GROUP                   "Memories and Memory Controllers/On-Chip"
set_module_property AUTHOR                  "ECE 5760 Stereo Vision"
set_module_property DESCRIPTION             "Row-banked dual-port on-chip memory.\
 200x1024 bytes (default), one M10K per row, with two Avalon-MM slaves\
 matching the original altera_avalon_onchip_memory2 Onchip_SRAM in\
 Computer_System.qsys plus a private parallel-read conduit for the\
 stereo SAD engine."
set_module_property INTERNAL                false
set_module_property OPAQUE_ADDRESS_MAP      true
set_module_property EDITABLE                true
set_module_property ELABORATION_CALLBACK    elaborate

# -----------------------------------------------------------------------------
# Source files
# -----------------------------------------------------------------------------
add_fileset             QUARTUS_SYNTH  QUARTUS_SYNTH  "" ""
set_fileset_property    QUARTUS_SYNTH  TOP_LEVEL                       stereo_onchip_ram
set_fileset_property    QUARTUS_SYNTH  ENABLE_RELATIVE_INCLUDE_PATHS   false
set_fileset_property    QUARTUS_SYNTH  ENABLE_FILE_OVERWRITE_MODE      true
add_fileset_file        stereo_onchip_ram.sv  SYSTEM_VERILOG  PATH    stereo_onchip_ram.sv  TOP_LEVEL_FILE

add_fileset             SIM_VERILOG    SIM_VERILOG    "" ""
set_fileset_property    SIM_VERILOG    TOP_LEVEL                       stereo_onchip_ram
add_fileset_file        stereo_onchip_ram.sv  SYSTEM_VERILOG  PATH    stereo_onchip_ram.sv

# -----------------------------------------------------------------------------
# Parameters
#
# These are forwarded to the SystemVerilog module as HDL parameters and also
# drive the address span / port widths declared in the elaboration callback.
# -----------------------------------------------------------------------------
add_parameter           N_ROWS              INTEGER  200
set_parameter_property  N_ROWS              DEFAULT_VALUE        200
set_parameter_property  N_ROWS              DISPLAY_NAME         "Number of row banks (rows)"
set_parameter_property  N_ROWS              UNITS                None
set_parameter_property  N_ROWS              ALLOWED_RANGES       1:256
set_parameter_property  N_ROWS              HDL_PARAMETER        true
set_parameter_property  N_ROWS              AFFECTS_GENERATION   true
set_parameter_property  N_ROWS              DESCRIPTION          "One M10K is allocated per row.\
 Default 200 matches FRAME_HEIGHT in DE1_SoC_Computer.v."

add_parameter           ROW_BYTES           INTEGER  1024
set_parameter_property  ROW_BYTES           DEFAULT_VALUE        1024
set_parameter_property  ROW_BYTES           DISPLAY_NAME         "Bytes per row (stride)"
set_parameter_property  ROW_BYTES           UNITS                None
set_parameter_property  ROW_BYTES           ALLOWED_RANGES       {256 512 1024 2048}
set_parameter_property  ROW_BYTES           HDL_PARAMETER        true
set_parameter_property  ROW_BYTES           AFFECTS_GENERATION   true
set_parameter_property  ROW_BYTES           DESCRIPTION          "Stride per row in bytes; must be a power of 2.\
 Default 1024 matches the Video_In_DMA X-Y stride for width=640."

# -----------------------------------------------------------------------------
# Elaboration callback
#
# Runs after the user sets parameter values. We compute derived port widths
# and address spans here so that the component re-elaborates correctly when
# parameters change.
# -----------------------------------------------------------------------------
proc elaborate {} {
    set N_ROWS    [get_parameter_value N_ROWS]
    set ROW_BYTES [get_parameter_value ROW_BYTES]

    set total_bytes  [expr {$N_ROWS * $ROW_BYTES}]
    set s1_addr_w    [expr {int(ceil(log($total_bytes)     / log(2)))}]
    set s2_addr_w    [expr {int(ceil(log($total_bytes / 4) / log(2)))}]
    set sad_col_w    [expr {int(ceil(log($ROW_BYTES)       / log(2)))}]
    set sad_data_w   [expr {$N_ROWS * 8}]

    # -------------------------------------------------------------------------
    # Clock interface
    # -------------------------------------------------------------------------
    add_interface             clk    clock  end
    set_interface_property    clk    clockRate         0
    set_interface_property    clk    ENABLED           true
    add_interface_port        clk    clk    clk    Input 1

    # -------------------------------------------------------------------------
    # Reset interface
    # -------------------------------------------------------------------------
    add_interface             reset  reset  end
    set_interface_property    reset  associatedClock   clk
    set_interface_property    reset  synchronousEdges  DEASSERT
    set_interface_property    reset  ENABLED           true
    add_interface_port        reset  reset  reset  Input 1

    # -------------------------------------------------------------------------
    # Avalon-MM slave  s1  : 8-bit, byte-addressable, fixed read latency 1
    #
    # Targeted by Video_In_Subsystem.video_in_dma_master in the parent system.
    # The DMA writes a 640x200 X-Y frame at 1024-byte stride starting at
    # 0x08000000. addressUnits=SYMBOLS so the address is a byte address.
    # -------------------------------------------------------------------------
    add_interface             s1     avalon end
    set_interface_property    s1     addressUnits                       SYMBOLS
    set_interface_property    s1     associatedClock                    clk
    set_interface_property    s1     associatedReset                    reset
    set_interface_property    s1     bitsPerSymbol                      8
    set_interface_property    s1     burstOnBurstBoundariesOnly         false
    set_interface_property    s1     burstcountUnits                    WORDS
    set_interface_property    s1     explicitAddressSpan                $total_bytes
    set_interface_property    s1     holdTime                           0
    set_interface_property    s1     linewrapBursts                     false
    set_interface_property    s1     maximumPendingReadTransactions     0
    set_interface_property    s1     maximumPendingWriteTransactions    0
    set_interface_property    s1     readLatency                        1
    set_interface_property    s1     readWaitTime                       0
    set_interface_property    s1     setupTime                          0
    set_interface_property    s1     timingUnits                        Cycles
    set_interface_property    s1     writeWaitTime                      0
    set_interface_property    s1     ENABLED                            true
    add_interface_port        s1     s1_address      address     Input  $s1_addr_w
    add_interface_port        s1     s1_chipselect   chipselect  Input  1
    add_interface_port        s1     s1_clken        clken       Input  1
    add_interface_port        s1     s1_write        write       Input  1
    add_interface_port        s1     s1_read         read        Input  1
    add_interface_port        s1     s1_writedata    writedata   Input  8
    add_interface_port        s1     s1_readdata     readdata    Output 8

    # -------------------------------------------------------------------------
    # Avalon-MM slave  s2  : 32-bit, word-addressable, byte-enabled,
    #                        fixed read latency 1
    #
    # Targeted by ARM_A9_HPS.h2f_axi_master AND EBAB_video_in.avalon_master in
    # the parent system. addressUnits=WORDS so the slave's address port is a
    # word index (Qsys handles byte<->word translation in the interconnect).
    # -------------------------------------------------------------------------
    add_interface             s2     avalon end
    set_interface_property    s2     addressUnits                       WORDS
    set_interface_property    s2     associatedClock                    clk
    set_interface_property    s2     associatedReset                    reset
    set_interface_property    s2     bitsPerSymbol                      8
    set_interface_property    s2     burstOnBurstBoundariesOnly         false
    set_interface_property    s2     burstcountUnits                    WORDS
    set_interface_property    s2     explicitAddressSpan                $total_bytes
    set_interface_property    s2     holdTime                           0
    set_interface_property    s2     linewrapBursts                     false
    set_interface_property    s2     maximumPendingReadTransactions     0
    set_interface_property    s2     maximumPendingWriteTransactions    0
    set_interface_property    s2     readLatency                        1
    set_interface_property    s2     readWaitTime                       0
    set_interface_property    s2     setupTime                          0
    set_interface_property    s2     timingUnits                        Cycles
    set_interface_property    s2     writeWaitTime                      0
    set_interface_property    s2     ENABLED                            true
    add_interface_port        s2     s2_address      address     Input  $s2_addr_w
    add_interface_port        s2     s2_chipselect   chipselect  Input  1
    add_interface_port        s2     s2_clken        clken       Input  1
    add_interface_port        s2     s2_write        write       Input  1
    add_interface_port        s2     s2_read         read        Input  1
    add_interface_port        s2     s2_byteenable   byteenable  Input  4
    add_interface_port        s2     s2_writedata    writedata   Input  32
    add_interface_port        s2     s2_readdata     readdata    Output 32

    # -------------------------------------------------------------------------
    # Conduit  sad_port  : private SAD parallel-read interface
    #
    # Not part of the Avalon fabric. Export this in the parent Qsys system to
    # bring it out as ports on the generated Computer_System wrapper, then
    # wire those ports straight into mem_block_intf in DE1_SoC_Computer.v.
    #
    #   sad_re                : read enable (currently advisory, M10Ks read every cycle)
    #   sad_col[sad_col_w-1:0]: byte column 0..ROW_BYTES-1 (same value applied to every row)
    #   sad_rdata[N_ROWS*8-1:0]: flat row-byte bus; row r byte at [(r+1)*8-1 -: 8]
    # -------------------------------------------------------------------------
    add_interface             sad_port  conduit  end
    set_interface_property    sad_port  associatedClock  clk
    set_interface_property    sad_port  associatedReset  reset
    set_interface_property    sad_port  ENABLED          true
    add_interface_port        sad_port  sad_re      re      Input  1
    add_interface_port        sad_port  sad_col     col     Input  $sad_col_w
    add_interface_port        sad_port  sad_rdata   rdata   Output $sad_data_w
}
