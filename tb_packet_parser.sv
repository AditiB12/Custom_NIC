`timescale 1ns/1ps
module tb_packet_parser;

  // Clock and reset
  logic aclk;
  logic aresetn;

  // AXI-Stream signals
  logic [511:0] s_axis_tdata;
  logic [63:0]  s_axis_tkeep;
  logic [47:0]  s_axis_tuser;
  logic         s_axis_tvalid;
  logic         s_axis_tlast;
  logic         s_axis_tready;

  logic [511:0] m_axis_tdata;
  logic [63:0]  m_axis_tkeep;
  logic [47:0]  m_axis_tuser;
  logic         m_axis_tvalid;
  logic         m_axis_tlast;
  logic         m_axis_tready;

  // Instantiate your parser
  packet_parser dut (
    .aclk           (aclk),
    .aresetn        (aresetn),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tuser   (s_axis_tuser),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tlast   (s_axis_tlast),
    .s_axis_tready  (s_axis_tready),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tkeep   (m_axis_tkeep),
    .m_axis_tuser   (m_axis_tuser),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tready  (m_axis_tready)
  );

  // Generate clock 250MHz = 4ns period
  initial aclk = 0;
  always #2 aclk = ~aclk;

  // Downstream always ready to receive
  assign m_axis_tready = 1'b1;

  // Task to send one packet beat
  task send_packet(input [511:0] data);
    @(posedge aclk);
    s_axis_tdata  <= data;
    s_axis_tkeep  <= 64'hFFFFFFFFFFFFFFFF;
    s_axis_tuser  <= 48'h0;
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= 1'b1;
    @(posedge aclk);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  endtask

  initial begin
    // Initialize
    aresetn       = 0;
    s_axis_tvalid = 0;
    s_axis_tlast  = 0;
    s_axis_tdata  = 0;
    s_axis_tkeep  = 0;
    s_axis_tuser  = 0;

    // Hold reset for 10 cycles
    repeat(10) @(posedge aclk);
    aresetn = 1;
    repeat(5) @(posedge aclk);

    // ---------------------------------------------------
    // Send a fake IPv4/TCP packet
    // We construct the first 64 bytes manually:
    //
    // Bytes 0-5:   dst MAC  = AA:BB:CC:DD:EE:FF
    // Bytes 6-11:  src MAC  = 11:22:33:44:55:66
    // Bytes 12-13: ethertype = 0x0800 (IPv4)
    // Bytes 14-23: IP header (partial)
    //   byte 23:  protocol = 0x06 (TCP)
    // Bytes 26-29: src IP  = 192.168.1.10  = C0A8010A
    // Bytes 30-33: dst IP  = 10.0.0.1      = 0A000001
    // Bytes 34-35: src port = 1234          = 04D2
    // Bytes 36-37: dst port = 80            = 0050
    // ---------------------------------------------------
    
    begin
        logic [511:0] pkt;
        pkt = 512'h0;

        pkt[111:96]  = 16'h0800;
        pkt[191:184] = 8'h11;
        pkt[239:208] = 32'h08080808;
        pkt[271:240] = 32'hC0A80101;
        pkt[287:272] = 16'h0035;
        pkt[303:288] = 16'hC001;

        // Fake IEX-TP / DEEP header
        pkt[(42*8) +: 16] = 16'h0001;
        pkt[(44*8) +: 16] = 16'h8004;
        pkt[(46*8) +: 32] = 32'd1;

        send_packet(pkt);
    end

    repeat(5) @(posedge aclk);

    // Send a second packet with different IPs
    begin
      logic [511:0] pkt;
      pkt = 512'h0;
      pkt[111:96]  = 16'h0800;        // IPv4
      pkt[191:184] = 8'h11;           // UDP
      pkt[239:208] = 32'h08080808;    // src IP 8.8.8.8
      pkt[271:240] = 32'hC0A80101;    // dst IP 192.168.1.1
      pkt[287:272] = 16'h0035;        // src port 53 (DNS)
      pkt[303:288] = 16'hC001;        // dst port 49153
      send_packet(pkt);
    end

    repeat(10) @(posedge aclk);
    $display("Simulation done!");
    $finish;
  end

endmodule
