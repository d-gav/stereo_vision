/*
 * DE1-SoC "Computer" system memory map (ARM side).
 * Matches the usual Cornell / BRL4 layout used with NIOS-based FPGA bridge code:
 *  - HW_REGS_BASE is the lightweight bus region; VIDEO_IN_BASE is an OFFSET into
 *    that region (so lw_virtual_base + VIDEO_IN_BASE + reg_offset is correct).
 * Vendored here so `stereo_c` builds without copying headers from a parallel tree.
 * If your Qsys/Quartus project moved peripherals, update from your
 * sopc/address map or your course-provided `address_map_arm_brl4.h`.
 */
#ifndef ADDRESS_MAP_ARM_BRL4_H
#define ADDRESS_MAP_ARM_BRL4_H

/* Lightweight FPGA slave region (for VIDEO_IN, keys, etc.) */
#define HW_REGS_BASE   0xFF200000u
#define HW_REGS_SPAN   0x00020000u

/* Offset from HW_REGS_BASE to Video-In DMA slave (see address_map_arm.h: 0xFF203060) */
#define VIDEO_IN_BASE  0x00003060u

/* On-chip and SDRAM frame buffers (VGA + video-in pixel DMA targets) */
#define SDRAM_BASE         0xC0000000u
#define FPGA_ONCHIP_BASE   0xC8000000u
#define FPGA_ONCHIP_SPAN   0x00040000u
#define FPGA_CHAR_BASE     0xC9000000u
#define FPGA_CHAR_SPAN     0x00002000u

#endif
