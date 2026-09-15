module deep_decode (
  input  logic         aclk,
  input  logic         aresetn,

  // opennic axi stream
  input  logic [511:0] s_axis_tdata,
  input  logic [47:0]  s_axis_tuser,
  input  logic [63:0]  s_axis_tkeep, 
  input  logic         s_axis_tvalid,
  input  logic         s_axis_tlast,
  output logic         s_axis_tready,

  // deep data
  output logic [63:0]  out_price,
  output logic [31:0]  out_size,
  output logic [63:0]  out_symbol, 
  output logic         out_valid
);
  assign s_axis_tready = 1'b1;

  logic [1023:0] window;
  logic [511:0]  prev_tdata;
  logic [7:0]    byte_ptr, next_byte_ptr;
  logic          is_first_beat;

  assign window = {s_axis_tdata, prev_tdata};

  logic [7:0]  p [7];
  logic [7:0]  safe_p [6];
  logic [15:0] msg_len [6];
  logic        msg_valid [6];
  
  logic [1023:0] stg1_window;
  logic [7:0]    stg1_p [6];
  logic          stg1_msg_valid [6];
  logic          stg1_valid;

  always_comb begin
    p[0] = byte_ptr;
    
    for (int i = 0; i < 6; i++) begin
      safe_p[i] = (p[i] > 126) ? 8'd126 : p[i];
      
      msg_len[i] = window[safe_p[i]*8 +: 16]; //message length in first 2 bytes
      
      p[i+1] = p[i] + msg_len[i] + 2;
      msg_valid[i] = (p[i] < 64);
    end
    
    next_byte_ptr = p[0];
    for (int i = 6; i >= 0; i--) begin
      if (p[i] >= 64) begin
        next_byte_ptr = p[i] - 64; 
      end
    end
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      byte_ptr      <= 0;
      is_first_beat <= 1'b1;
      stg1_valid    <= 1'b0;
      prev_tdata    <= '0;
    end else begin
      stg1_valid <= 1'b0; 

      if (s_axis_tvalid) begin
        prev_tdata <= s_axis_tdata;

        if (is_first_beat) begin
          if (!s_axis_tlast) begin
            is_first_beat <= 1'b0;
            byte_ptr      <= 8'd18; 
          end
        end else begin
          stg1_valid  <= 1'b1;
          stg1_window <= window;
          byte_ptr    <= next_byte_ptr;
          
          for (int i = 0; i < 6; i++) begin
            stg1_p[i]         <= p[i];
            stg1_msg_valid[i] <= msg_valid[i];
          end

          if (s_axis_tlast) is_first_beat <= 1'b1;
        end
      end
    end
  end

  logic [159:0] stg2_extracted [6];
  logic         stg2_is_target [6];
  logic         stg2_valid;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      stg2_valid <= 1'b0;
      for (int i = 0; i < 6; i++) stg2_is_target[i] <= 1'b0;
    end else begin
      stg2_valid <= stg1_valid;
      
      if (stg1_valid) begin
        for (int i = 0; i < 6; i++) begin
          logic [7:0] m_type = stg1_window[(stg1_p[i] + 2)*8 +: 8];
          
          stg2_is_target[i] <= (m_type == 8'h38 || m_type == 8'h35) && stg1_msg_valid[i];
          
          stg2_extracted[i] <= {
            stg1_window[(stg1_p[i] + 12)*8 +: 64], // symbol (Length[2] + Type[1] + Flags[1] + Timestamp[8])
            stg1_window[(stg1_p[i] + 24)*8 +: 64], // price
            stg1_window[(stg1_p[i] + 20)*8 +: 32]  // size
          };
        end
      end
    end
  end

  logic [2:0]   pack_cnt;
  logic [159:0] pack_data [6];

  always_comb begin
    pack_cnt = 0;
    for (int i = 0; i < 6; i++) pack_data[i] = '0;
    
    for (int i = 0; i < 6; i++) begin
      if (stg2_is_target[i]) begin
        pack_data[pack_cnt] = stg2_extracted[i];
        pack_cnt++;
      end
    end
  end

  (* ram_style = "distributed" *) logic [159:0] fifo_data [32][6];
  (* ram_style = "distributed" *) logic [2:0]   fifo_cnt  [32];
  
  logic [4:0] wr_ptr;
  logic [4:0] rd_ptr;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wr_ptr <= '0;
    end else if (stg2_valid && pack_cnt > 0) begin
      fifo_cnt[wr_ptr] <= pack_cnt;
      for (int i = 0; i < 6; i++) fifo_data[wr_ptr][i] <= pack_data[i];
      wr_ptr <= wr_ptr + 1;
    end
  end

  logic         row_active;
  logic [2:0]   pop_idx;
  logic [2:0]   current_row_cnt;
  logic [159:0] current_row_data [6];

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rd_ptr     <= '0;
      row_active <= 1'b0;
      out_valid  <= 1'b0;
      out_symbol <= '0;
      out_price  <= '0;
      out_size   <= '0;
    end else begin
      out_valid <= 1'b0; 

      if (row_active) begin
        {out_symbol, out_price, out_size} <= current_row_data[pop_idx];
        out_valid <= 1'b1;
        
        if (pop_idx == current_row_cnt - 1) begin
          row_active <= 1'b0; // Row exhausted
        end else begin
          pop_idx <= pop_idx + 1;
        end

      end else if (wr_ptr != rd_ptr) begin
        logic [2:0] cnt = fifo_cnt[rd_ptr];
        
        // output index 0 immediately
        {out_symbol, out_price, out_size} <= fifo_data[rd_ptr][0];
        out_valid <= 1'b1;
        
        // buffer them for subsequent cycles
        if (cnt > 1) begin
          current_row_cnt <= cnt;
          for (int i = 0; i < 6; i++) current_row_data[i] <= fifo_data[rd_ptr][i];
          row_active <= 1'b1;
          pop_idx    <= 3'd1;
        end
        
        rd_ptr <= rd_ptr + 1;
      end
    end
  end

endmodule
