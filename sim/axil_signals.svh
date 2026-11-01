// Shared wires for the test master and the peripheral under test.
wire [11:0] s_axi_awaddr, s_axi_araddr;
wire [2:0] s_axi_awprot, s_axi_arprot;
wire s_axi_awvalid, s_axi_awready, s_axi_wvalid, s_axi_wready;
wire [31:0] s_axi_wdata, s_axi_rdata;
wire [3:0] s_axi_wstrb;
wire [1:0] s_axi_bresp, s_axi_rresp;
wire s_axi_bvalid, s_axi_bready, s_axi_arvalid, s_axi_arready;
wire s_axi_rvalid, s_axi_rready;
