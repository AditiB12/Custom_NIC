`timescale 1ns/1ps

module packet_parser (
    input  logic         aclk,
    input  logic         aresetn,

    input  logic [511:0] s_axis_tdata,
    input  logic [63:0]  s_axis_tkeep,
    input  logic [47:0]  s_axis_tuser,
    input  logic         s_axis_tvalid,
    input  logic         s_axis_tlast,
    output logic         s_axis_tready,

    output logic [511:0] m_axis_tdata,
    output logic [63:0]  m_axis_tkeep,
    output logic [47:0]  m_axis_tuser,
    output logic         m_axis_tvalid,
    output logic         m_axis_tlast,
    input  logic         m_axis_tready
);

    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] ethertype;
    logic [7:0]  ip_protocol;
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic [15:0] src_port;
    logic [15:0] dst_port;
    


    logic [31:0] pkt_count;
    logic [31:0] ipv4_count;
    logic [31:0] arp_count;
    logic [31:0] tcp_count;
    logic [31:0] udp_count;
    logic [31:0] icmp_count;
    logic [31:0] drop_count;

    logic in_packet;
    logic beat_fire;
    logic first_beat;

    logic is_ipv4;
    logic is_arp;
    logic is_tcp;
    logic is_udp;
    logic is_icmp;
    logic is_deep_candidate;
    logic [7:0] udp_payload_byte0;

    logic [31:0] deep_candidate_count;

    logic [15:0] iex_tp_version;
    logic [15:0] iex_tp_protocol_id;
    logic [31:0] iex_tp_channel_id;
    logic        is_iex_deep;
    logic [31:0] iex_deep_count;

    assign dst_mac   = s_axis_tdata[47:0];
    assign src_mac   = s_axis_tdata[95:48];

    assign ethertype = s_axis_tdata[111:96];

    assign ip_protocol = s_axis_tdata[191:184];

    assign beat_fire  = s_axis_tvalid && s_axis_tready;
    assign first_beat = beat_fire && !in_packet;
    assign is_ipv4 = (ethertype == 16'h0800);
    assign is_arp  = (ethertype == 16'h0806);
    assign is_tcp  = is_ipv4 && (ip_protocol == 8'd6);
    assign is_udp  = is_ipv4 && (ip_protocol == 8'd17);
    assign is_icmp = is_ipv4 && (ip_protocol == 8'd1);

    // UDP payload starts at byte 42 if Ethernet + IPv4 no options + UDP.
    assign udp_payload_byte0 = s_axis_tdata[(42*8) +: 8];

    // For now, just detect UDP as possible DEEP candidate.
    // Later narrow by dst_port / multicast IP / payload format.
    assign is_deep_candidate = first_beat && is_udp;

    assign src_ip = {
        s_axis_tdata[215:208],
        s_axis_tdata[223:216],
        s_axis_tdata[231:224],
        s_axis_tdata[239:232]
    };

    assign dst_ip = {
        s_axis_tdata[247:240],
        s_axis_tdata[255:248],
        s_axis_tdata[263:256],
        s_axis_tdata[271:264]
    };

    assign src_port = {s_axis_tdata[279:272], s_axis_tdata[287:280]};
    assign dst_port = {s_axis_tdata[295:288], s_axis_tdata[303:296]};

  

    // AXI-Stream passthrough.
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tuser  = s_axis_tuser;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tvalid = s_axis_tvalid;

    assign s_axis_tready = m_axis_tready;

    assign iex_tp_version     = s_axis_tdata[(42*8) +: 16];
    assign iex_tp_protocol_id = {
        s_axis_tdata[(45*8) +: 8],
        s_axis_tdata[(44*8) +: 8]
    };
    assign iex_tp_channel_id  = s_axis_tdata[(46*8) +: 32];

    assign is_iex_deep =
        first_beat &&
        is_udp &&
        (iex_tp_protocol_id == 16'h8004) &&
        (iex_tp_channel_id  == 32'd1);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            in_packet  <= 1'b0;
            pkt_count  <= 32'd0;
            ipv4_count <= 32'd0;
            arp_count  <= 32'd0;
            tcp_count  <= 32'd0;
            udp_count  <= 32'd0;
            icmp_count <= 32'd0;
            drop_count <= 32'd0;
            deep_candidate_count <= 32'd0;
            iex_deep_count <= 32'd0;
        end else if (beat_fire) begin
            if (first_beat) begin
                pkt_count <= pkt_count + 1;

                if (is_ipv4)
                    ipv4_count <= ipv4_count + 1;
                else if (is_arp)
                    arp_count <= arp_count + 1;

                if (is_tcp)
                    tcp_count <= tcp_count + 1;
                else if (is_udp)
                    udp_count <= udp_count + 1;
                else if (is_icmp)
                    icmp_count <= icmp_count + 1;

                if (is_deep_candidate)
                    deep_candidate_count <= deep_candidate_count + 1;
                if (is_iex_deep)
                    iex_deep_count <= iex_deep_count + 1;
            end

            if (s_axis_tlast)
                in_packet <= 1'b0;
            else
                in_packet <= 1'b1;
 

            
        end
    end
    
    
    // Simulation-only debug output.
    // synthesis translate_off
    always_ff @(posedge aclk) begin
        if (aresetn && first_beat) begin
            $display(
                "PKT: ethertype=%h proto=%h src_ip=%h dst_ip=%h src_port=%h dst_port=%h udp_payload0=%h deep_candidate=%b counts(pkt=%0d ipv4=%0d arp=%0d tcp=%0d udp=%0d icmp=%0d deep=%0d)",
                ethertype,
                ip_protocol,
                src_ip,
                dst_ip,
                src_port,
                dst_port,
                udp_payload_byte0,
                is_deep_candidate,
                iex_tp_version,
                iex_tp_protocol_id,
                iex_tp_channel_id,
                is_iex_deep,
                pkt_count,
                ipv4_count,
                arp_count,
                tcp_count,
                udp_count,
                icmp_count,
                deep_candidate_count,
                iex_deep_count
            );
        end
        
    end
    // synthesis translate_on

endmodule
