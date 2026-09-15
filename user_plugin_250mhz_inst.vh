localparam C_NUM_USER_BLOCK = 1;

// Make sure for all the unused reset pair, corresponding bits in
// \"mod_rst_done\" are tied to 0
assign mod_rst_done[15:C_NUM_USER_BLOCK] = {(16-C_NUM_USER_BLOCK){1'b1}};

// -------------------------------------------------------
// Intermediate wires: packet_parser output to p2p input
// -------------------------------------------------------
wire [511:0] parsed_rx_tdata;
wire [63:0]  parsed_rx_tkeep;
wire         parsed_rx_tvalid;
wire         parsed_rx_tlast;
wire         parsed_rx_tready;

// -------------------------------------------------------
// Instantiate packet_parser on the RX path
// Sits between the network adapter and p2p
// -------------------------------------------------------
packet_parser parser_inst (
  .aclk          (axis_aclk),
  .aresetn       (mod_rstn[0]),

  .s_axis_tdata  (s_axis_adap_rx_250mhz_tdata[511:0]),
  .s_axis_tkeep  (s_axis_adap_rx_250mhz_tkeep[63:0]),
  .s_axis_tuser  (s_axis_adap_rx_250mhz_tuser_src[47:0]),
  .s_axis_tvalid (s_axis_adap_rx_250mhz_tvalid[0]),
  .s_axis_tlast  (s_axis_adap_rx_250mhz_tlast[0]),
  .s_axis_tready (s_axis_adap_rx_250mhz_tready[0]),

  .m_axis_tdata  (parsed_rx_tdata),
  .m_axis_tkeep  (parsed_rx_tkeep),
  .m_axis_tuser  (),
  .m_axis_tvalid (parsed_rx_tvalid),
  .m_axis_tlast  (parsed_rx_tlast),
  .m_axis_tready (parsed_rx_tready)
);

p2p_250mhz #(
  .NUM_QDMA    (NUM_QDMA),
  .NUM_INTF    (NUM_PHYS_FUNC)
) p2p_250mhz_inst (
  .s_axil_awvalid                   (axil_p2p_awvalid),
  .s_axil_awaddr                    (axil_p2p_awaddr),
  .s_axil_awready                   (axil_p2p_awready),
  .s_axil_wvalid                    (axil_p2p_wvalid),
  .s_axil_wdata                     (axil_p2p_wdata),
  .s_axil_wready                    (axil_p2p_wready),
  .s_axil_bvalid                    (axil_p2p_bvalid),
  .s_axil_bresp                     (axil_p2p_bresp),
  .s_axil_bready                    (axil_p2p_bready),
  .s_axil_arvalid                   (axil_p2p_arvalid),
  .s_axil_araddr                    (axil_p2p_araddr),
  .s_axil_arready                   (axil_p2p_arready),
  .s_axil_rvalid                    (axil_p2p_rvalid),
  .s_axil_rdata                     (axil_p2p_rdata),
  .s_axil_rresp                     (axil_p2p_rresp),
  .s_axil_rready                    (axil_p2p_rready),
  .s_axis_qdma_h2c_tvalid           (s_axis_qdma_h2c_tvalid),
  .s_axis_qdma_h2c_tdata            (s_axis_qdma_h2c_tdata),
  .s_axis_qdma_h2c_tkeep            (s_axis_qdma_h2c_tkeep),
  .s_axis_qdma_h2c_tlast            (s_axis_qdma_h2c_tlast),
  .s_axis_qdma_h2c_tuser_size       (s_axis_qdma_h2c_tuser_size),
  .s_axis_qdma_h2c_tuser_src        (s_axis_qdma_h2c_tuser_src),
  .s_axis_qdma_h2c_tuser_dst        (s_axis_qdma_h2c_tuser_dst),
  .s_axis_qdma_h2c_tready           (s_axis_qdma_h2c_tready),
  .m_axis_qdma_c2h_tvalid           (m_axis_qdma_c2h_tvalid),
  .m_axis_qdma_c2h_tdata            (m_axis_qdma_c2h_tdata),
  .m_axis_qdma_c2h_tkeep            (m_axis_qdma_c2h_tkeep),
  .m_axis_qdma_c2h_tlast            (m_axis_qdma_c2h_tlast),
  .m_axis_qdma_c2h_tuser_size       (m_axis_qdma_c2h_tuser_size),
  .m_axis_qdma_c2h_tuser_src        (m_axis_qdma_c2h_tuser_src),
  .m_axis_qdma_c2h_tuser_dst        (m_axis_qdma_c2h_tuser_dst),
  .m_axis_qdma_c2h_tready           (m_axis_qdma_c2h_tready),
  .m_axis_adap_tx_250mhz_tvalid     (m_axis_adap_tx_250mhz_tvalid),
  .m_axis_adap_tx_250mhz_tdata      (m_axis_adap_tx_250mhz_tdata),
  .m_axis_adap_tx_250mhz_tkeep      (m_axis_adap_tx_250mhz_tkeep),
  .m_axis_adap_tx_250mhz_tlast      (m_axis_adap_tx_250mhz_tlast),
  .m_axis_adap_tx_250mhz_tuser_size (m_axis_adap_tx_250mhz_tuser_size),
  .m_axis_adap_tx_250mhz_tuser_src  (m_axis_adap_tx_250mhz_tuser_src),
  .m_axis_adap_tx_250mhz_tuser_dst  (m_axis_adap_tx_250mhz_tuser_dst),
  .m_axis_adap_tx_250mhz_tready     (m_axis_adap_tx_250mhz_tready),
  .s_axis_adap_rx_250mhz_tvalid     (parsed_rx_tvalid),
  .s_axis_adap_rx_250mhz_tdata      (parsed_rx_tdata),
  .s_axis_adap_rx_250mhz_tkeep      (parsed_rx_tkeep),
  .s_axis_adap_rx_250mhz_tlast      (parsed_rx_tlast),
  .s_axis_adap_rx_250mhz_tuser_size (s_axis_adap_rx_250mhz_tuser_size),
  .s_axis_adap_rx_250mhz_tuser_src  (s_axis_adap_rx_250mhz_tuser_src),
  .s_axis_adap_rx_250mhz_tuser_dst  (s_axis_adap_rx_250mhz_tuser_dst),
  .s_axis_adap_rx_250mhz_tready     (parsed_rx_tready),
  .mod_rstn                         (mod_rstn[0]),
  .mod_rst_done                     (mod_rst_done[0]),
`ifdef __au55n__
  .ref_clk_100mhz                   (ref_clk_100mhz),
`elsif __au55c__
  .ref_clk_100mhz                   (ref_clk_100mhz),
`elsif __au50__
  .ref_clk_100mhz                   (ref_clk_100mhz),
`elsif __au280__
  .ref_clk_100mhz                   (ref_clk_100mhz),
`endif
  .axil_aclk                        (axil_aclk),
  .axis_aclk                        (axis_aclk)
);
