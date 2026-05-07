/*
 * DE1-SoC "Computer" system memory map (ARM side).
 * Matches the usual Cornell / BRL4 layout used with NIOS-based FPGA bridge code:
 *  - HW_REGS_BASE is the lightweight bus region; VIDEO_IN_BASE is an OFFSET into
 *    that region (so lw_virtual_base + VIDEO_IN_BASE + reg_offset is correct).
 * This copy at the project root matches the classic layout next to `stereo_c/`.
 * The canonical path for the C build is `stereo_c/include/address_map_arm_brl4.h`
 * (identical). If your Qsys/Quartus project moved peripherals, update from your
 * sopc/address map or your course-provided `address_map_arm_brl4.h`.
 */
#ifndef ADDRESS_MAP_ARM_BRL4_H
#define ADDRESS_MAP_ARM_BRL4_H

/* Lightweight FPGA slave region (for VIDEO_IN, keys, etc.) */
#define HW_REGS_BASE   0xFF200000u
#define HW_REGS_SPAN   0x00020000u

/* Offset from HW_REGS_BASE to Video-In DMA slave (see address_map_arm.h: 0xFF203060) */
#define VIDEO_IN_BASE  0x00003060u

/* PIO offsets from HW_REGS_BASE. Match Computer_System.qsys baseAddress fields:
 *   pio_small_pen.s1 = 0x0010   (SGM P1, drives mem_block_intf.sgm_p1)
 *   pio_big_pen.s1   = 0x0020   (SGM P2, drives mem_block_intf.sgm_p2)
 *   pio_max_disp.s1  = 0x0030   (max disparity)
 *   pio_min_disp.s1  = 0x0040   (min disparity / dark cutoff)
 * All four are 32-bit Output PIOs. */
#define PIO_SMALL_PEN_BASE 0x00000010u
#define PIO_BIG_PEN_BASE   0x00000020u
#define PIO_MAX_DISP_BASE  0x00000030u
#define PIO_MIN_DISP_BASE  0x00000040u

/* On-chip and SDRAM frame buffers (VGA + video-in pixel DMA targets) */
#define SDRAM_BASE         0xC0000000u
#define FPGA_ONCHIP_BASE   0xC8000000u
#define FPGA_ONCHIP_SPAN   0x00040000u
#define FPGA_CHAR_BASE     0xC9000000u
#define FPGA_CHAR_SPAN     0x00002000u

#endif
