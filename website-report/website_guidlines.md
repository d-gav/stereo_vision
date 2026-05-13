# ECE 5760 Final Website Report Guidelines

Source: [ECE 5760 Final Design Project](https://vanhunteradams.com/DE1/Final_Project/Final_Project.html), accessed 2026-05-13.

Project: FPGA/HPS stereo vision depth system on the Terasic DE1-SoC.

Team: Daniel, Demetrios, Ezra.

Use this file as the checklist for building the final project website/report. The course page says the final report is a required HTML submission and should include the major sections below. Omit only sections that truly do not apply to this project.

## Report Structure

### 1. Project Introduction

- Write a one-sentence sound bite for the project.
  - Suggested draft: "We built a real-time stereo-vision depth pipeline on the DE1-SoC that computes disparity from two analog camera feeds using FPGA hardware, HPS software, and Python reference models."
- Summarize what was built:
  - Dual-camera PAL/NTSC video capture.
  - Stereo image splitting, swapping, calibration/rectification/undistortion work.
  - SAD/block-matching disparity on FPGA RTL.
  - C implementation on the HPS for comparison/control.
  - Python pipeline for algorithm experiments and golden-reference testing.
  - VGA display of input and/or disparity output.
- Explain why it was built:
  - Explore real-time stereo depth estimation.
  - Compare hardware, C, and Python implementations of the same algorithm.
  - Understand the tradeoff between accuracy, resource use, and frame-rate constraints.

### 2. High-Level Design

- Explain the motivation and source of the idea:
  - Stereo depth perception inspired by two-camera geometry and real-time embedded vision.
  - Class project goal: meaningful mix of FPGA hardware, HPS software, and external hardware.
- Include background math and algorithm concepts:
  - Stereo cameras estimate depth by measuring horizontal disparity between corresponding image features.
  - Larger disparity generally means a closer object; smaller disparity means farther away.
  - Sum of Absolute Differences (SAD) block matching compares a reference window in one image against shifted candidate windows in the other image.
  - Important parameters: `window_w/window_h`, `BLOCK_SIZE`, `max_disparity`, `MAX_DISP`, `v_shift`, and `NUM_SAD_UNITS`.
  - Discuss why rectification matters and how vertical mismatch affects SAD.
  - If used in final results, explain radial or polynomial undistortion mapping.
- Add a logical block diagram:
  - Cameras -> video decoder/front end -> Video-In DMA -> on-chip RAM/frame buffer.
  - On-chip frame data -> FPGA stereo matcher and/or HPS C matcher.
  - Disparity output -> VGA pixel buffer -> VGA display.
  - Python pipeline -> parameter sweeps, calibration artifacts, and RTL testbench fixtures.
- Discuss hardware/software tradeoffs:
  - FPGA RTL offers parallelism and deterministic timing, but requires careful memory access and resource budgeting.
  - HPS C is easier to iterate and debug, but is more limited for pixel-parallel matching.
  - Python is best for algorithm exploration, visualization, and offline testing.
  - Custom on-chip RAM and parallel row prefetching improve access bandwidth for SAD.
  - Window size and maximum disparity affect accuracy, compute cost, memory bandwidth, and latency.
- Discuss relevant intellectual property at a high level:
  - Intel/Altera FPGA IP and Qsys components.
  - Terasic DE1-SoC board support material.
  - Cornell course baseline code.
  - OpenCV/Python packages, Icarus Verilog, and other toolchain dependencies.
  - Any borrowed code, generated code, calibration data, or public-domain/reference designs.

### 3. Program And Hardware Design

- Provide enough detail that another ECE 5760 student could rebuild the system.
- Hardware/platform details to include:
  - Terasic DE1-SoC / Cyclone V target.
  - Dual analog cameras and PAL/NTSC captured frame layout.
  - VGA pixel buffer and Video-In DMA memory map.
  - 640x480 VGA output, 640x288 captured video region, 1024-byte stride.
  - Default split between left/right subimages and the black center bar detection.
- RTL implementation details to include:
  - Top-level integration in `DE1_SoC_Computer.v`.
  - Active matcher/data-path modules such as `mem_block_intf_d.v`, `block_match.sv`, `block_match_pkg.sv`, `column_prefetch_parallel.sv`, `stereo_onchip_ram.sv`, `sliding_window.sv`, and related mapper modules.
  - Memory read latency assumptions and row-banked memory interface.
  - How `NUM_SAD_UNITS` parallelizes the block matcher.
  - Output signals: `disp_valid`, `disp_out_x`, `disp_out_y`, and `disp_out_value`.
  - Any SGM-style penalty parameters that remain in the design.
- C implementation details to include:
  - `stereo_c/` SAD matcher and runtime controls.
  - mmap access to the VGA and video buffers.
  - NEON versus scalar SAD paths.
  - Runtime parameters and hotkeys.
  - How the C implementation mirrors RTL/Python defaults.
- Python implementation details to include:
  - `sterio-vision-python/stereo_depth_system/` as the reference pipeline.
  - `run_stereo_experiments.py` method sweeps and output artifacts.
  - `python-testing/` scripts for calibration, distortion fits, mapper generation, and parameter sweeps.
  - `stereo_rtl_test/` Icarus Verilog testbench that compares RTL behavior against image fixtures.
- Identify tricky parts:
  - Synchronizing camera capture, memory layout, and VGA display.
  - Correctly splitting and swapping the left/right camera views.
  - Dealing with rectification error and lens distortion.
  - Matching memory bandwidth to the SAD pipeline.
  - Keeping RTL, C, and Python implementations aligned.
  - Handling generated LUTs, test images, and output artifacts.
- Include things tried that did not work:
  - Older one-row-at-a-time prefetch path if replaced.
  - Any failed mapper, calibration, window-size, max-disparity, or v-shift experiments.
  - Any Qsys memory/IP approach that was too slow or did not expose the needed parallel reads.
- Specifically reference all reused design/code:
  - Cornell/Toronto Computer System 15 baseline.
  - Intel/Altera IP.
  - Terasic examples or board documentation.
  - OpenCV and Python libraries.
  - Any external calibration method, paper, or tutorial.

### 4. Results Of The Design

- Include test evidence:
  - Photos/screenshots of the VGA output.
  - Input stereo image pairs.
  - Disparity output images.
  - Parameter sweep plots or result grids.
  - RTL simulation outputs from the Icarus testbench.
  - Relevant SignalTap, waveform, or scope captures if available.
- Report speed and responsiveness:
  - FPGA pipeline throughput or latency.
  - HPS C runtime for representative settings.
  - Python reference runtime where useful.
  - Whether the display hesitates, flickers, or updates interactively.
  - Effects of `BLOCK_SIZE`, `MAX_DISP`, and `NUM_SAD_UNITS`.
- Report accuracy and quality:
  - Qualitative comparison of disparity maps against visible scene structure.
  - Effects of swapping cameras, bar detection, v-shift, rectification, and undistortion.
  - Failure modes such as textureless surfaces, repeated patterns, lighting mismatch, camera noise, and occlusion.
  - Any numeric metric available from image tests or synthetic fixtures.
- Discuss safety:
  - Low-voltage lab hardware only.
  - Secure camera wiring and board setup.
  - No hazardous actuators, RF transmitters, lasers, or human-connected electronics unless added later.
- Discuss usability:
  - Runtime controls and hotkeys.
  - Display modes such as grayscale versus RGB332/jet if applicable.
  - How easy it is for another user to run the demo and interpret the output.
  - Accessibility concerns such as colorblind-safe visualization if using a colormap.

### 5. Conclusions

- Compare results to expectations:
  - What worked well?
  - What did not meet expectations?
  - Which implementation was most useful for debugging: RTL, C, or Python?
  - Which parameter choices gave the best quality/performance balance?
- Describe what should be done differently next time:
  - Better camera mounting/baseline.
  - More rigorous calibration/rectification.
  - Improved cost aggregation, Census matching, SGM, filtering, or confidence metrics.
  - Higher memory bandwidth or deeper pipelining.
  - Better visualization and interactive parameter tuning.
- Discuss standards and legal/IP considerations:
  - Relevant video timing conventions and VGA/PAL/NTSC assumptions.
  - Intel/Altera and Terasic IP usage.
  - Open-source library licenses.
  - Public-domain or borrowed code/designs.
  - Whether there are patent, trademark, reverse-engineering, or NDA issues.

### 6. Appendix A: Required Permissions

The course page says Appendix A must include the required permission statements for:

- Whether the report may appear on the course website.
- Whether the demo video may appear on the course YouTube channel.

Use the exact wording from the course page when choosing the approve or do-not-approve option for each item. Do not leave this out; the course page states that missing permission language costs points.

Team decision placeholders:

- Course website report permission: TODO choose approve or do-not-approve.
- Course YouTube video permission: TODO choose approve or do-not-approve.

### 7. Additional Appendices

- Commented Verilog/SystemVerilog listings or links:
  - `block_match.sv`
  - `block_match_pkg.sv`
  - `mem_block_intf_d.v`
  - `column_prefetch_parallel.sv`
  - `stereo_onchip_ram.sv`
  - Any mapper or rectification modules used in the final build.
- C source listings or links:
  - Main HPS stereo matcher files.
  - Build instructions and runtime options.
- Python source listings or links:
  - Reference matching methods.
  - Sweep driver.
  - Calibration or mapper-generation scripts.
  - RTL testbench runner.
- Schematics:
  - Include external camera wiring if any hardware beyond the DE1-SoC board is built or modified.
- Team task list:
  - Daniel: TODO.
  - Demetrios: TODO.
  - Ezra: TODO.
- References:
  - Data sheets.
  - Vendor pages.
  - Borrowed code/designs.
  - Background papers or websites.
  - Calibration and stereo-matching references.

## Website Packaging And Submission Checklist

- Put the whole website in one directory.
- Name the directory with the group members' concatenated NetIDs.
- Use `index.html` or another clearly linked main HTML file.
- Keep filenames case-consistent with hyperlinks.
- Use only alphanumeric characters and underscores in submitted filenames.
- Make all links relative to the main page.
- Do not include video files in the submitted ZIP; host videos elsewhere and embed/link them.
- Compress/minimize images before submission.
- Test the website on another computer before submitting.
- Test on multiple operating systems or browsers if possible.
- ZIP the final directory.
- Upload to the Cornell Box link provided by the course staff.

## Suggested Website Page Outline

1. Title, team members, project photo/video embed.
2. One-sentence sound bite.
3. Introduction and motivation.
4. High-level architecture diagram.
5. Stereo algorithm background.
6. Hardware design.
7. RTL design.
8. HPS C design.
9. Python reference/testing pipeline.
10. Results and demo evidence.
11. Problems encountered and failed approaches.
12. Conclusions and future work.
13. Appendix A permissions.
14. Code listings, schematics, task ownership, and references.

## Assets To Collect

- Final demo photo of the DE1-SoC/camera setup.
- Short hosted demo video link.
- Block diagram of the complete system.
- Memory map diagram.
- SAD block-matching diagram.
- Screenshots of input frame, split left/right images, and disparity output.
- Parameter sweep images/plots from Python experiments.
- RTL simulation output image and any waveforms.
- Table comparing RTL, C, and Python behavior/performance.
- Table of final parameters used in the demo.
- Annotated list of source files used in the final build.
