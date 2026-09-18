# Custom FPGA Network Card

## Introduction

In this project, our group explored using a Xilinx Alveo U55C FPGA as a custom high-speed network card for low-latency packet processing and market-data acceleration. 

Our project is built on top of the OpenNIC shell framework and focuses on building a low-latency FPGA packet-processing pipeline capable of parsing and filtering live Ethernet traffic directly in hardware. The project specifically explores how FPGA logic can be used to identify and process IEX DEEP market-data traffic directly from the AXI-stream datapath while minimizing software overhead and latency.

Throughout the project, we worked through both the infrastructure and protocol-processing sides of the system, including compiling and deploying the OpenNIC shell onto the Alveo U55C FPGA, bringing up FPGA-backed Linux network interfaces through PCIe, integrating custom SystemVerilog parser modules into the OpenNIC datapath, developing an RTL simulation workflow in Vivado, implementing IEX-TP and DEEP packet detection logic, and extending the design toward streaming DEEP message extraction and filtering.

This README serves both as:

1. a summary of the overall project architecture and workflow
2. a practical step-by-step guide for reproducing the setup, compiling the FPGA bitstream, programming the board, running simulations, and testing the parser pipeline

The guide documents many of the issues we encountered during development (Vivado setup, CMAC licensing, PCIe rescanning, AXI-stream handling, etc.). We hope that this serves as a comprehensive guide such that future contributors can easily reproduce the environment and continue extending the project.


## Part 1: Generating the bitstream on hft06
The goal of this stage was to generate the OpenNIC FPGA bitstream for the Alveo U55C board.


After going to the OpenNIC repository, first source the Vivado environment:
```bash
 source /tools/Xilinx/Vivado/2024.2/settings64.sh 
 ```
 Launching the OpenNIC build using a TCL script:
 ```bash
 vivado -mode batch -source build.tcl -tclargs -board au55c
 ```
 If successful, the bitstream will be generated at:
 ```bash
 ~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/open_nic_shell.bit
 ```
 Next, transfer the generated bitstream to the hft01 host server. From there:
 ```bash
 scp kx11@hft06:~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/open_nic_shell.bit ~/open_nic_shell.bit
 ```
 Move it into the expected directory:
 ```bash
 mkdir -p ~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1

mv ~/open_nic_shell.bit ~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/
```

## Part 2: Board bring up on hft01
The goal of this stage was to program the U55C FPGA with the OpenNIC bitstream, refresh the PCIe device, and bring the Linux network interface up.

First confirm that the Xilinx card is visible:
```bash
lspci | grep Xilinx
```
Expected output to confirm that the U55C card was visible over PCIe:
```bash
83:00.0 Network controller: Xilinx Corporation Device 903f
83:00.1 Processing accelerators: Xilinx Corporation Device 505d
```
Source Vivado:
```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
```
When launching Vivado, we encountered the issue:
```bash
couldn't load file "libxv_commontasks.so": libtinfo.so.5: cannot open shared object file
```
Since Ubuntu 22.04 only provides a newer version of the system library, `libtinfo.so.5` did not exist on the system. To bypass this issue, we created a local compatibility workaround using a symbolic link.
```bash
mkdir -p ~/libfix
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 ~/libfix/libtinfo.so.5
export LD_LIBRARY_PATH=~/libfix:$LD_LIBRARY_PATH
```
Vivado can now be successfully directed to the available version.

Launching the Vivado TCL mode:
```bash
vivado -mode tcl
```
Programming the FPGA inside Vivado:
```bash
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {/home/kx11/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/open_nic_shell.bit} [current_hw_device]
program_hw_devices [current_hw_device]
exit
```
Startup status should show "HIGH" when FPGA fabric is successfully configured.

Need Linux to re-detect the PCIe device using setup script (script internally perpends 0000). Press [c] when prompted:
```bash
sudo ~/script/setup_device.sh 83:00.0
```
After PCIe rescan, the final step is to bring up the relevant interfaces:
```bash
sudo /usr/sbin/ip link set ens1f0 up
sudo /usr/sbin/ip link set ens1f1 up
```
To verify interface status:
```bash
ip -br link
```
Should see at least one physical link established. In our case it was:
```bash
ens1f0  DOWN  <NO-CARRIER,BROADCAST,MULTICAST,UP>
ens1f1  UP    <BROADCAST,MULTICAST,UP,LOWER_UP>
Link detected: yes
```

## Part 3: Integrating the Packet Parser into OpenNIC

After successfully bringing up the OpenNIC shell on the U55C FPGA, the next stage was integrating custom packet-processing logic directly into the FPGA datapath.

The custom parser logic was implemented inside:

```bash
~/open-nic-shell/plugin/p2p/box_250mhz/
```

Main files:

```text
packet_parser.sv         // Main AXI-stream packet parser. Extracts Ethernet/IP/UDP fields, performs IEX-TP detection, packet classification, and forwards packets through the OpenNIC datapath.

deep_decode.sv           // Streaming DEEP market-data decoder. Parses DEEP message structures, filters PLU updates, extracts fields such as price/size/symbol, and handles cross-beat message alignment using a 1024-bit sliding window.

tb_packet_parser.sv      // SystemVerilog testbench used to simulate and validate packet_parser.sv and deep_decode.sv using synthetic Ethernet/IP/UDP/IEX packets.

user_plugin_250mhz_inst.vh // OpenNIC integration wrapper. Connects packet_parser.sv into the RX AXI-stream datapath between the network adapter and p2p module inside the 250 MHz OpenNIC plugin region.
```

The parser was connected into the AXI-stream datapath inside the OpenNIC plugin region.

The parser operates on:

```text
512-bit AXI-stream datapath
64 bytes transferred per clock cycle
250 MHz datapath clock
```

Current functionality includes:

* Ethernet field extraction
* IPv4 field extraction
* UDP/TCP protocol detection
* packet counters
* IEX-TP detection
* candidate DEEP packet classification

The parser operates as a passthrough module by default, meaning packets continue propagating through the OpenNIC datapath unchanged while protocol fields are simultaneously decoded in parallel hardware logic.

---

## Part 4: Running RTL Simulation

Before rebuilding the FPGA bitstream, simulation was used to validate parser functionality.

Move into the parser directory:

```bash
cd ~/open-nic-shell/plugin/p2p/box_250mhz
```

Run Vivado simulation:

```bash
vivado -mode batch -source run_parser_sim.tcl
```

The simulation testbench (`tb_packet_parser.sv`) injects synthetic packets directly into the AXI-stream interface.

Current simulation packets include:

* IPv4/TCP packets
* IPv4/UDP packets
* synthetic IEX DEEP packets

Debug output is printed using `$display`.

To inspect parser output:

```bash
grep -i "PKT:\|IEX\|ERROR\|FAIL" vivado.log | tail -100
```

Successful simulation output should show:

```text
iex_protocol=8004
iex_channel=00000001
is_iex_deep=1
```

---

## Part 5: Rebuilding OpenNIC with Parser Logic

After simulation correctness is verified, rebuild the OpenNIC shell.

Move into the script directory:

```bash
cd ~/open-nic-shell/script
```

Source Vivado:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
```

Export the CMAC license server:

```bash
export LM_LICENSE_FILE=2100@10.30.200.59
```

Launch the OpenNIC build:

```bash
vivado -mode batch -source build.tcl -tclargs -board au55c
```

If compilation succeeds, the generated bitstream should appear at:

```bash
~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/open_nic_shell.bit
```

---

## Part 6: Programming the FPGA with Updated Parser Logic

Copy the updated bitstream onto `hft01`.

On `hft06`:

```bash
scp ~/open-nic-shell/build/au55c/open_nic_shell/open_nic_shell.runs/impl_1/open_nic_shell.bit kx11@hft01:~
```

On `hft01`, source Vivado:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh
```

Launch Vivado TCL:

```bash
vivado -mode tcl
```

Program the FPGA:

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {/home/kx11/open_nic_shell.bit} [current_hw_device]
program_hw_devices [current_hw_device]
exit
```

---

## Part 7: PCIe Rescan and Interface Bring-Up

After programming the FPGA, Linux must rediscover the PCIe device.

Run:

```bash
sudo ~/script/setup_device.sh 83:00.0
```

Bring interfaces up:

```bash
sudo /usr/sbin/ip link set ens1f0 up
sudo /usr/sbin/ip link set ens1f1 up
```

Verify interface status:

```bash
ip -br link
```

Expected output:

```text
ens1f1  UP  <BROADCAST,MULTICAST,UP,LOWER_UP>
```

---

## Part 8: Validating Live Traffic

Verify that traffic still passes correctly through the FPGA datapath.

Example ping test:

```bash
ping -I ens1f1 10.30.203.56 -c 5
```

Successful output should show:

```text
0% packet loss
sub-millisecond latency
```

This confirms that FPGA datapath remains operational and that custom parser logic did not break packet forwarding. 

---

## Part 9: Current DEEP Decoder Architecture

The current parser pipeline operates as:

```text
Ethernet frame
        ↓
IPv4 packet
        ↓
UDP packet
        ↓
IEX-TP detection
        ↓
DEEP packet classification
        ↓
deep_decode.sv
        ↓
PLU message extraction
```

Current DEEP decoder functionality includes:

* IEX-TP parsing
* DEEP message identification
* PLU message filtering
* message type extraction
* symbol/price/size extraction
* 1024-bit sliding window handling for cross-beat messages

The decoder currently targets:

```text
0x38 → buy-side PLU updates
0x35 → sell-side PLU updates
```

To support streaming packet processing at line rate, the decoder combines both the current and previous AXI-stream beats into a larger 1024-bit processing window. This allows DEEP messages spanning AXI beat boundaries to still be parsed correctly.

---






