
# (C) 2001-2026 Altera Corporation. All rights reserved.
# Your use of Altera Corporation's design tools, logic functions and 
# other software and tools, and its AMPP partner logic functions, and 
# any output files any of the foregoing (including device programming 
# or simulation files), and any associated documentation or information 
# are expressly subject to the terms and conditions of the Altera 
# Program License Subscription Agreement, Altera MegaCore Function 
# License Agreement, or other applicable license agreement, including, 
# without limitation, that your use is for the sole purpose of 
# programming logic devices manufactured by Altera and sold by Altera 
# or its authorized distributors. Please refer to the applicable 
# agreement for further details.

# ACDS 18.1 625 win32 2026.04.16.14:54:56

# ----------------------------------------
# vcs - auto-generated simulation script

# ----------------------------------------
# This script provides commands to simulate the following IP detected in
# your Quartus project:
#     Computer_System
# 
# Altera recommends that you source this Quartus-generated IP simulation
# script from your own customized top-level script, and avoid editing this
# generated script.
# 
# To write a top-level shell script that compiles Altera simulation libraries
# and the Quartus-generated IP in your project, along with your design and
# testbench files, follow the guidelines below.
# 
# 1) Copy the shell script text from the TOP-LEVEL TEMPLATE section
# below into a new file, e.g. named "vcs_sim.sh".
# 
# 2) Copy the text from the DESIGN FILE LIST & OPTIONS TEMPLATE section into
# a separate file, e.g. named "filelist.f".
# 
# ----------------------------------------
# # TOP-LEVEL TEMPLATE - BEGIN
# #
# # TOP_LEVEL_NAME is used in the Quartus-generated IP simulation script to
# # set the top-level simulation or testbench module/entity name.
# #
# # QSYS_SIMDIR is used in the Quartus-generated IP simulation script to
# # construct paths to the files required to simulate the IP in your Quartus
# # project. By default, the IP script assumes that you are launching the
# # simulator from the IP script location. If launching from another
# # location, set QSYS_SIMDIR to the output directory you specified when you
# # generated the IP script, relative to the directory from which you launch
# # the simulator.
# #
# # Source the Quartus-generated IP simulation script and do the following:
# # - Compile the Quartus EDA simulation library and IP simulation files.
# # - Specify TOP_LEVEL_NAME and QSYS_SIMDIR.
# # - Compile the design and top-level simulation module/entity using
# #   information specified in "filelist.f".
# # - Override the default USER_DEFINED_SIM_OPTIONS. For example, to run
# #   until $finish(), set to an empty string: USER_DEFINED_SIM_OPTIONS="".
# # - Run the simulation.
# #
# source <script generation output directory>/synopsys/vcs/vcs_setup.sh \
# TOP_LEVEL_NAME=<simulation top> \
# QSYS_SIMDIR=<script generation output directory> \
# USER_DEFINED_ELAB_OPTIONS="\"-f filelist.f\"" \
# USER_DEFINED_SIM_OPTIONS=<simulation options for your design>
# #
# # TOP-LEVEL TEMPLATE - END
# ----------------------------------------
# 
# ----------------------------------------
# # DESIGN FILE LIST & OPTIONS TEMPLATE - BEGIN
# #
# # Compile all design files and testbench files, including the top level.
# # (These are all the files required for simulation other than the files
# # compiled by the Quartus-generated IP simulation script)
# #
# +systemverilogext+.sv
# <design and testbench files, compile-time options, elaboration options>
# #
# # DESIGN FILE LIST & OPTIONS TEMPLATE - END
# ----------------------------------------
# 
# IP SIMULATION SCRIPT
# ----------------------------------------
# If Computer_System is one of several IP cores in your
# Quartus project, you can generate a simulation script
# suitable for inclusion in your top-level simulation
# script by running the following command line:
# 
# ip-setup-simulation --quartus-project=<quartus project>
# 
# ip-setup-simulation will discover the Altera IP
# within the Quartus project, and generate a unified
# script which supports all the Altera IP within the design.
# ----------------------------------------
# ACDS 18.1 625 win32 2026.04.16.14:54:56
# ----------------------------------------
# initialize variables
TOP_LEVEL_NAME="Computer_System"
QSYS_SIMDIR="./../../"
QUARTUS_INSTALL_DIR="C:/programs/intelfpga/18.1/quartus/"
SKIP_FILE_COPY=0
SKIP_SIM=0
USER_DEFINED_ELAB_OPTIONS=""
USER_DEFINED_SIM_OPTIONS="+vcs+finish+100"
# ----------------------------------------
# overwrite variables - DO NOT MODIFY!
# This block evaluates each command line argument, typically used for 
# overwriting variables. An example usage:
#   sh <simulator>_setup.sh SKIP_SIM=1
for expression in "$@"; do
  eval $expression
  if [ $? -ne 0 ]; then
    echo "Error: This command line argument, \"$expression\", is/has an invalid expression." >&2
    exit $?
  fi
done

# ----------------------------------------
# initialize simulation properties - DO NOT MODIFY!
ELAB_OPTIONS=""
SIM_OPTIONS=""
if [[ `vcs -platform` != *"amd64"* ]]; then
  :
else
  :
fi

# ----------------------------------------
# copy RAM/ROM files to simulation directory
if [ $SKIP_FILE_COPY -eq 0 ]; then
  cp -f $QSYS_SIMDIR/submodules/altera_up_video_char_mode_rom_128.mif ./
  cp -f $QSYS_SIMDIR/submodules/altera_up_video_fb_color_rom.mif ./
fi

vcs -lca -timescale=1ps/1ps -sverilog +verilog2001ext+.v -ntb_opts dtm $ELAB_OPTIONS $USER_DEFINED_ELAB_OPTIONS \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/altera_primitives.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/220model.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/sgate.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/altera_mf.v \
  $QUARTUS_INSTALL_DIR/eda/sim_lib/altera_lnsim.sv \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/synopsys/cyclonev_atoms_ncrypt.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/synopsys/cyclonev_hmi_atoms_ncrypt.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/cyclonev_atoms.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/synopsys/cyclonev_hssi_atoms_ncrypt.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/cyclonev_hssi_atoms.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/synopsys/cyclonev_pcie_hip_atoms_ncrypt.v \
  -v $QUARTUS_INSTALL_DIR/eda/sim_lib/cyclonev_pcie_hip_atoms.v \
  $QSYS_SIMDIR/submodules/verbosity_pkg.sv \
  $QSYS_SIMDIR/submodules/avalon_utilities_pkg.sv \
  $QSYS_SIMDIR/submodules/avalon_mm_pkg.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_avalon_st_adapter_error_adapter_0.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_avalon_st_adapter_error_adapter_0.sv \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Video_Stream_Splitter.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Video_Stream_Merger.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Edge_Detection_Router_Controller.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_gaussian_smoothing_filter.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_sobel_operator.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_nonmaximum_suppression.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_hysteresis.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_pixel_info_shift_register.v \
  $QSYS_SIMDIR/submodules/altera_up_edge_detection_data_shift_register.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Edge_Detection.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Chroma_Upsampler.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem_Chroma_Filter.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_PLL_video_pll.vo \
  $QSYS_SIMDIR/submodules/altera_avalon_mm_slave_bfm.sv \
  $QSYS_SIMDIR/submodules/altera_avalon_interrupt_sink.sv \
  $QSYS_SIMDIR/submodules/altera_avalon_clock_source.sv \
  $QSYS_SIMDIR/submodules/altera_avalon_reset_source.sv \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS_hps_io_border_memory.sv \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS_hps_io_border_hps_io.sv \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS_hps_io_border.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_avalon_st_adapter.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_rsp_mux.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_arbitrator.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_rsp_demux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_cmd_mux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_cmd_demux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_router_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1_router.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_avalon_st_adapter.v \
  $QSYS_SIMDIR/submodules/altera_avalon_st_handshake_clock_crosser.v \
  $QSYS_SIMDIR/submodules/altera_avalon_st_clock_crosser.v \
  $QSYS_SIMDIR/submodules/altera_avalon_st_pipeline_base.v \
  $QSYS_SIMDIR/submodules/altera_std_synchronizer_nocut.v \
  $QSYS_SIMDIR/submodules/altera_merlin_width_adapter.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_address_alignment.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_burst_uncompressor.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_rsp_mux_003.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_rsp_mux_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_rsp_mux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_rsp_demux_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_rsp_demux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_mux_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_mux_001.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_mux.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_demux_003.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_demux_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_cmd_demux.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_burst_adapter.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_burst_adapter_uncmpr.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_burst_adapter_13_1.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_burst_adapter_new.sv \
  $QSYS_SIMDIR/submodules/altera_incr_burst_converter.sv \
  $QSYS_SIMDIR/submodules/altera_wrap_burst_converter.sv \
  $QSYS_SIMDIR/submodules/altera_default_burst_converter.sv \
  $QSYS_SIMDIR/submodules/altera_avalon_st_pipeline_stage.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_traffic_limiter.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_reorder_memory.sv \
  $QSYS_SIMDIR/submodules/altera_avalon_sc_fifo.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router_006.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router_005.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router_004.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router_003.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router_002.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0_router.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_slave_agent.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_master_agent.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_axi_master_ni.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_slave_translator.sv \
  $QSYS_SIMDIR/submodules/altera_merlin_master_translator.sv \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In_RGB_Resampler.v \
  $QSYS_SIMDIR/submodules/altera_up_video_dma_control_slave.v \
  $QSYS_SIMDIR/submodules/altera_up_video_dma_to_memory.v \
  $QSYS_SIMDIR/submodules/altera_up_video_dma_to_stream.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In_DMA.v \
  $QSYS_SIMDIR/submodules/altera_up_video_clipper_add.v \
  $QSYS_SIMDIR/submodules/altera_up_video_clipper_drop.v \
  $QSYS_SIMDIR/submodules/altera_up_video_clipper_counters.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In_Clipper.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In_Chroma_Resampler.v \
  $QSYS_SIMDIR/submodules/altera_up_YCrCb_to_RGB_converter.v \
  $QSYS_SIMDIR/submodules/altera_up_RGB_to_YCrCb_converter.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In_CSC.v \
  $QSYS_SIMDIR/submodules/altera_up_video_itu_656_decoder.v \
  $QSYS_SIMDIR/submodules/altera_up_video_decoder_add_endofpacket.v \
  $QSYS_SIMDIR/submodules/altera_up_video_camera_decoder.v \
  $QSYS_SIMDIR/submodules/altera_up_video_dual_clock_fifo.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Video_In.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem_Edge_Detection_Subsystem.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Pixel_RGB_Resampler.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Pixel_FIFO.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Pixel_DMA.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_PLL.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Dual_Clock_FIFO.v \
  $QSYS_SIMDIR/submodules/altera_up_avalon_video_vga_timing.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Controller.v \
  $QSYS_SIMDIR/submodules/altera_up_video_128_character_rom.v \
  $QSYS_SIMDIR/submodules/altera_up_video_fb_color_rom.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Char_Buffer.v \
  $QSYS_SIMDIR/submodules/altera_up_video_alpha_blender_normal.v \
  $QSYS_SIMDIR/submodules/altera_up_video_alpha_blender_simple.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem_VGA_Alpha_Blender.v \
  $QSYS_SIMDIR/submodules/altera_up_avalon_reset_from_locked_signal.v \
  $QSYS_SIMDIR/submodules/Computer_System_System_PLL_sys_pll.vo \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS_hps_io.v \
  $QSYS_SIMDIR/submodules/questa_mvc_svapi.svh \
  $QSYS_SIMDIR/submodules/mgc_common_axi.sv \
  $QSYS_SIMDIR/submodules/mgc_axi_master.sv \
  $QSYS_SIMDIR/submodules/mgc_axi_slave.sv \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS_fpga_interfaces.sv \
  $QSYS_SIMDIR/submodules/altera_reset_controller.v \
  $QSYS_SIMDIR/submodules/altera_reset_synchronizer.v \
  $QSYS_SIMDIR/submodules/Computer_System_irq_mapper.sv \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_4.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_3.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_2.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_1.v \
  $QSYS_SIMDIR/submodules/Computer_System_mm_interconnect_0.v \
  $QSYS_SIMDIR/submodules/Computer_System_pio_0.v \
  $QSYS_SIMDIR/submodules/Computer_System_Video_In_Subsystem.v \
  $QSYS_SIMDIR/submodules/Computer_System_VGA_Subsystem.v \
  $QSYS_SIMDIR/submodules/Computer_System_System_PLL.v \
  $QSYS_SIMDIR/submodules/Computer_System_SDRAM.v \
  $QSYS_SIMDIR/submodules/Computer_System_SDRAM_test_component.v \
  $QSYS_SIMDIR/submodules/altera_up_avalon_video_dma_ctrl_addr_trans.v \
  $QSYS_SIMDIR/submodules/Computer_System_Onchip_SRAM.v \
  $QSYS_SIMDIR/submodules/Computer_System_EBAB_video_in.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_serial_bus_controller.v \
  $QSYS_SIMDIR/submodules/altera_up_slow_clock_generator.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_dc2.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_d5m.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_lcm.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ltm.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_de1_soc.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_de2_115.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_de2i_150.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_de10_standard.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_audio.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_adv7180.v \
  $QSYS_SIMDIR/submodules/altera_up_av_config_auto_init_ob_adv7181.v \
  $QSYS_SIMDIR/submodules/Computer_System_AV_Config.v \
  $QSYS_SIMDIR/submodules/Computer_System_ARM_A9_HPS.v \
  $QSYS_SIMDIR/Computer_System.v \
  -top $TOP_LEVEL_NAME
# ----------------------------------------
# simulate
if [ $SKIP_SIM -eq 0 ]; then
  ./simv $SIM_OPTIONS $USER_DEFINED_SIM_OPTIONS
fi
