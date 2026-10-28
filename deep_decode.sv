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
  logic [7:0]    byte_ptr;
  logic          is_first_beat;

  assign window = {s_axis_tdata, prev_tdata};

  
  //msg walker
  localparam int NUM_CAND = 6; //no more hardcoding 
  localparam int FIRST_MSG_WINDOW_BYTE = 82; 
  //first msg starts 

  logic [16:0] p [0:NUM_CAND];  //make window a big value so it doesnt overflow back into <128 for a huge packet
  logic [16:0] msg_end [0:NUM_CAND-1];  //where p[i+1] starts
  logic [15:0] msg_len [0:NUM_CAND-1];

  logic chain_valid [0:NUM_CAND];
  logic header_valid [0:NUM_CAND-1]; //check if theres enough bytes to read msg's 2 byte length val 
  logic msg_complete [0:NUM_CAND-1];
  logic msg_take [0:NUM_CAND-1]; //move to decoding in stg2
  // Stage 1 registers
  logic [1023:0] stg1_window;
  logic [7:0]    stg1_p [0:NUM_CAND-1];
  logic [15:0]   stg1_msg_len [0:NUM_CAND-1];
  logic          stg1_msg_valid [0:NUM_CAND-1];
  logic          stg1_valid;

  // Stage 2 registers
  logic [159:0]  stg2_extracted [0:NUM_CAND-1];
  logic          stg2_is_target [0:NUM_CAND-1];
  logic          stg2_valid;

  logic          found_next;
  logic [7:0] next_byte_ptr;

  function automatic logic [6:0] count_keep(input logic [63:0] keep);
    logic [6:0] cnt;
    begin
        cnt = 0;
        for (int i = 0; i < 64; i++)
            cnt += keep[i];

        return cnt;
    end
  endfunction

  logic [2:0] pack_cnt;
  logic [159:0] pack_data [6];

  logic [6:0] prev_valid_bytes; //how many bytes in prev window were actually valid
  logic [6:0] curr_valid_bytes;
  logic [8:0] window_valid_bytes;

  assign curr_valid_bytes   = count_keep(s_axis_tkeep);
  assign window_valid_bytes = prev_valid_bytes + curr_valid_bytes;


  //compactor immediately before the fifo
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

//STAGE 0 NEW
  always_comb begin
    // defaults
    for (int i = 0; i <= NUM_CAND; i++) begin
        p[i]           = '0;
        chain_valid[i] = 1'b0;
    end

    for (int i = 0; i < NUM_CAND; i++) begin
        msg_len[i]      = '0;
        msg_end[i]      = '0;
        header_valid[i] = 1'b0;
        msg_complete[i] = 1'b0;
        msg_take[i]     = 1'b0;
    end

    // first unprocessed framed message
    p[0]           = byte_ptr;
    chain_valid[0] = 1'b1;

    for (int i = 0; i < NUM_CAND; i++) begin
        header_valid[i] = chain_valid[i] &&
            (p[i] <= 17'd126) &&
            ((p[i] + 2) <= window_valid_bytes);
            //need both msg len bytes 
        if (header_valid[i]) begin
          msg_len[i] = window[p[i]*8 +: 16];
          msg_end[i] = p[i] + 17'd2 + msg_len[i];
          msg_complete[i] = (msg_end[i] <= window_valid_bytes) &&
              (msg_end[i] <= 17'd128); //exclusive end, must fit inside sliding window and also match the real end of packet
          if (msg_complete[i]) begin
              p[i+1] = msg_end[i];
              chain_valid[i+1] = 1'b1;
          end

          // Normal window: only decode starts in lower 64 bytes
          // Final window: decode anything complete before packet end.
          msg_take[i] = msg_complete[i] && ((p[i] < 64) || s_axis_tlast);
          //replaces msg_valid[i] = (p[i] < 64), avoids decoding the same msg twice
        end
    end

    //find first unprocessed boundary in upper half, replaces old window shifting logic 
    next_byte_ptr = 0;
    logic found_next;
    found_next = 1'b0;

    for (int i = 0; i <= NUM_CAND; i++) begin
        if (!found_next && chain_valid[i] &&  p[i] >= 64 &&  p[i] <= 128) begin 
            next_byte_ptr = p[i] - 64;
            found_next = 1'b1;
        end
    end
  end

  //STAGE 1 NEW
  logic beat_fire;  //use this instead of js s_axis_valid since tready could be 0 during fifo phase and wrongly advance when beat hasnt been accepted
  assign beat_fire = s_axis_tvalid && s_axis_tready;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      byte_ptr         <= 0;
      is_first_beat    <= 1'b1;
      stg1_valid       <= 1'b0;
      prev_tdata       <= '0;
      prev_valid_bytes <= 0;

    end else begin
      stg1_valid <= 1'b0;
      if (beat_fire) begin
        if (is_first_beat) begin
          // Save packet bytes 0-63
          prev_tdata       <= s_axis_tdata;
          prev_valid_bytes <= curr_valid_bytes;
          if (!s_axis_tlast) begin
              is_first_beat <= 1'b0; //1st msg is packet byte 82 in{beat1, beat0}
              byte_ptr <= FIRST_MSG_WINDOW_BYTE;
          end
        end else begin
          // Current beat + previous beat make a valid window
          stg1_valid  <= 1'b1;
          stg1_window <= window;
          for (int i = 0; i < NUM_CAND; i++) begin
              stg1_p[i]         <= p[i][7:0];
              stg1_msg_valid[i] <= msg_take[i];
              stg1_msg_len[i]   <= msg_len[i];
          end
          prev_tdata       <= s_axis_tdata;
          prev_valid_bytes <= curr_valid_bytes;
          if (s_axis_tlast) begin
              is_first_beat <= 1'b1;
              byte_ptr      <= 0;
          end else begin
              byte_ptr <= next_byte_ptr;
          end
        end
      end
    end
  end

  //STAGE 2 NEW
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      stg2_valid <= 1'b0;
      for (int i = 0; i < 6; i++) begin
        stg2_is_target[i] <= 1'b0;
        stg2_extracted[i] <= '0;
      end
    end else begin
      stg2_valid <= stg1_valid;
      for (int i = 0; i < 6; i++) begin
        stg2_is_target[i] <= 1'b0;
        stg2_extracted[i] <= '0;
        if (stg1_valid && stg1_msg_valid[i] && stg1_msg_len[i] >= 16'd30) begin  //deep plu layut is 30 bytes
          //old stg2 was wrong since it read std1window before checking that the stg1msg was valid 
            if ((stg1_window[(stg1_p[i] + 2)*8 +: 8] == 8'h38) ||
                (stg1_window[(stg1_p[i] + 2)*8 +: 8] == 8'h35)) begin  //is plu
                stg2_is_target[i] <= 1'b1;
                stg2_extracted[i] <= {
                    stg1_window[(stg1_p[i] + 12)*8 +: 64],
                    stg1_window[(stg1_p[i] + 24)*8 +: 64],
                    stg1_window[(stg1_p[i] + 20)*8 +: 32]
                };
            end
        end
      end
    end
  end

  //each fifo is a row containing up to 6 decoded msgs
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

//old code with comments on code flaws and what had to be changed 
  //STAGE 0
  /*logic [7:0]  p [7];  //starting byte pos of each msg
  //need to calc where the 7th msg would begin for cases that cross boundaries 
  logic [7:0]  safe_p [6];  //clamped pos
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
      //last valid starting pos for a 2 byte read is byte 126
      
      msg_len[i] = window[safe_p[i]*8 +: 16]; //message length in first 2 bytes
      //flaw: endianness might be wrong , (idk gotta check) this 
      inteprets the lower addressed byte as the lsb
      //flaw: Clamping prevents an out-of-range read but doesn't make the data meaningful.
      p[i+1] = p[i] + msg_len[i] + 2;
      msg_valid[i] = (p[i] < 64); //msg starts in prev beat
      //intended approach was to process messages starting in the previous beat now, and leave messages starting in the current beat for the next cycle
      //code limitation: pointer p is limited to 256 addresses, this might cause inccorect modulos during overflow
      //flaw : super long comb chain, critical path might be too long for 4ns period
    end
    //at the next clk cycle, window shifts forward by one 512-bit/64-byte beat 
    next_byte_ptr = p[0];
    for (int i = 6; i >= 0; i--) begin
      if (p[i] >= 64) begin
        next_byte_ptr = p[i] - 64; 
        //want to find the first msg that starts at byte 64 or later 
      end
    end
  end
  //another big problem with stg0: no explicit mechanism to represent a parser state that is skipping over a long message or waiting for its next header
  //This becomes fragile when messages span multiple beats or when the next message starts beyond the available window.

//The underlying issue is that a 128-byte sliding window and an 8-bit pointer do not provide a robust general-purpose variable-length message parser.

  //STAGE 1
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
            //packet has an 18-byte header that must be skipped before reaching the first msg 
            //parser has to wait for the 2nd beat to build a 1024 bit sliding window 
          end
        end else begin
          stg1_valid  <= 1'b1; //stg 1 has produced a result 
          stg1_window <= window;
          byte_ptr    <= next_byte_ptr;
          
          for (int i = 0; i < 6; i++) begin
            stg1_p[i] <= p[i];
            stg1_msg_valid[i] <= msg_valid[i];
          end

          if (s_axis_tlast) is_first_beat <= 1'b1;
        end
      end
    end
  end

  //STAGE 2
  logic [159:0] stg2_extracted [6];
  logic         stg2_is_target [6];
  logic         stg2_valid;
  //6 potential outputs each containing 160 bits: symbol (64), price(64), size(32)

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
  end */