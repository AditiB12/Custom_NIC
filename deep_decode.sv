
module deep_decode (
  input logic aclk,
  input logic aresetn,

  // opennic axi stream
  input logic [511:0] s_axis_tdata,
  input logic [47:0] s_axis_tuser,
  input logic [63:0] s_axis_tkeep,
  input logic s_axis_tvalid,
  input logic s_axis_tlast,
  output logic s_axis_tready,

  // deep data
  output logic [7:0] out_msg_type,
  output logic [7:0] out_flags,
  output logic [63:0] out_timestamp,
  output logic [63:0] out_symbol,
  output logic [31:0] out_size,
  output logic [63:0] out_price,
  output logic out_valid,

  output logic parser_error,
  output logic candidate_overflow
);

  // NEW: 240-bit decoded message
  typedef struct packed {
    logic [7:0] msg_type;
    logic [7:0] flags;
    logic [63:0] timestamp;
    logic [63:0] symbol;
    logic [31:0] size;
    logic [63:0] price;
  } market_event_t;

  localparam logic [7:0] MSG_PLU_35 = 8'h35;
  localparam logic [7:0] MSG_PLU_38 = 8'h38;

  logic [1023:0] window;
  logic [511:0] prev_tdata;
  logic [16:0] byte_ptr;
  logic is_first_beat;

  assign window = {s_axis_tdata, prev_tdata};


  //msg walker
  localparam int NUM_CAND = 6; //no more hardcoding
  localparam int FIRST_MSG_WINDOW_BYTE = 82;
  //first msg starts

  logic [16:0] p [0:NUM_CAND]; //make window a big value so it doesnt overflow back into <128 for a huge packet
  logic [16:0] msg_end [0:NUM_CAND-1]; //where p[i+1] starts
  logic [15:0] msg_len [0:NUM_CAND-1];

  logic chain_valid [0:NUM_CAND];
  logic header_valid [0:NUM_CAND-1]; //check if theres enough bytes to read msg's 2 byte length val
  logic msg_complete [0:NUM_CAND-1];
  logic msg_take [0:NUM_CAND-1]; //move to decoding in stg2

  // Stage 1 registers
  logic [1023:0] stg1_window;
  logic [7:0] stg1_p [0:NUM_CAND-1];
  logic [15:0] stg1_msg_len [0:NUM_CAND-1];
  logic stg1_msg_valid [0:NUM_CAND-1];
  logic stg1_valid;

  // Stage 2 registers
  market_event_t stg2_extracted [0:NUM_CAND-1];
  logic stg2_is_target [0:NUM_CAND-1];
  logic stg2_valid;

  logic found_next;
  logic [16:0] next_byte_ptr;
  logic stage0_overflow;

  function automatic logic [6:0] count_keep(input logic [63:0] keep);
    logic [6:0] cnt;
    begin
      cnt = 0;
      for (int i = 0; i < 64; i++)
        cnt += keep[i];
      return cnt;
    end
  endfunction

  // NEW: check tkeep is contiguous
  function automatic logic keep_contiguous(input logic [63:0] keep);
    logic seen_zero;
    logic ok;
    begin
      seen_zero = 1'b0;
      ok = 1'b1;
      for (int i = 0; i < 64; i++) begin
        if (!keep[i])
          seen_zero = 1'b1;
        else if (seen_zero)
          ok = 1'b0;
      end
      return ok;
    end
  endfunction

  logic [2:0] pack_cnt;
  market_event_t pack_data [0:NUM_CAND-1];

  logic [6:0] prev_valid_bytes; //how many bytes in prev window were actually valid
  logic [6:0] curr_valid_bytes;
  logic [8:0] window_valid_bytes;

  assign curr_valid_bytes = count_keep(s_axis_tkeep);

  // FIX: current beat starts at byte 64, not prev_valid_bytes
  assign window_valid_bytes = 9'd64 + {2'b00, curr_valid_bytes};

  //compactor immediately before the fifo
  always_comb begin
    pack_cnt = 0;
    for (int i = 0; i < NUM_CAND; i++)
      pack_data[i] = '0;
    for (int i = 0; i < NUM_CAND; i++) begin
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
      p[i] = '0;
      chain_valid[i] = 1'b0;
    end
    for (int i = 0; i < NUM_CAND; i++) begin
      msg_len[i] = '0;
      msg_end[i] = '0;
      header_valid[i] = 1'b0;
      msg_complete[i] = 1'b0;
      msg_take[i] = 1'b0;
    end
    // first unprocessed framed message
    p[0] = byte_ptr;
    chain_valid[0] = 1'b1;
    for (int i = 0; i < NUM_CAND; i++) begin
      header_valid[i] = chain_valid[i] &&
          (p[i] <= 17'd126) &&
          ((p[i] + 17'd2) <= window_valid_bytes);
          //need both msg len bytes
      if (header_valid[i]) begin
        msg_len[i] = window[p[i]*8 +: 16];
        msg_end[i] = p[i] + 17'd2 + {1'b0, msg_len[i]};
        // FIX: need valid length, not necessarily entire
        // message inside window to find next boundary
        if (msg_len[i] != 0) begin
          p[i+1] = msg_end[i];
          chain_valid[i+1] = 1'b1;
        end
        // Need at least 32 bytes for PLU field extraction
        msg_complete[i] =  (msg_len[i] >= 16'd30) &&  ((p[i] + 17'd32) <= window_valid_bytes);
        // Normal window: only decode starts in lower 64 bytes
        // Final window: decode anything complete before packet end.
        msg_take[i] = msg_complete[i] &&  ((p[i] < 64) || s_axis_tlast) && (!s_axis_tlast || (msg_end[i] <= window_valid_bytes));
        //replaces msg_valid[i] = (p[i] < 64), avoids decoding the same msg twice
      end
    end
    //find first unprocessed boundary in upper half, replaces old window shifting logic
    next_byte_ptr = 0;
    found_next = 1'b0;
    for (int i = 0; i <= NUM_CAND; i++) begin
      if (!found_next && chain_valid[i] && p[i] >= 64) begin
        next_byte_ptr = p[i] - 17'd64;
        found_next = 1'b1;
      end
    end
    // NEW: detect more than 6 messages in lower half
    stage0_overflow = chain_valid[NUM_CAND] &&  (p[NUM_CAND] < 64);
    // FIX: if no next boundary found, preserve position
    // rather than silently restarting at byte zero
    if (!found_next) begin
      if (chain_valid[NUM_CAND])
        next_byte_ptr = (p[NUM_CAND] >= 64) ? p[NUM_CAND] - 17'd64  : 17'd0;
      else
        next_byte_ptr = (byte_ptr >= 64) ? byte_ptr - 17'd64 : 17'd0;
    end
  end


  //STAGE 1 NEW
  logic beat_fire; //use this instead of js s_axis_valid since tready could be 0 during fifo phase and wrongly advance when beat hasnt been accepted
  assign beat_fire = s_axis_tvalid && s_axis_tready;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      byte_ptr <= 0;
      is_first_beat <= 1'b1;
      stg1_valid <= 1'b0;
      prev_tdata <= '0;
      prev_valid_bytes <= 0;
      parser_error <= 1'b0;
      candidate_overflow <= 1'b0;
    end else begin
      stg1_valid <= 1'b0;
      if (beat_fire) begin
        // NEW: detect unsupported tkeep patterns
        if (!keep_contiguous(s_axis_tkeep) ||
            (!s_axis_tlast && s_axis_tkeep != 64'hFFFFFFFFFFFFFFFF))
          parser_error <= 1'b1;
        if (is_first_beat) begin
          // Save packet bytes 0-63
          prev_tdata <= s_axis_tdata;
          prev_valid_bytes <= curr_valid_bytes;
          if (!s_axis_tlast) begin
            is_first_beat <= 1'b0; //1st msg is packet byte 82 in{beat1, beat0}
            byte_ptr <= FIRST_MSG_WINDOW_BYTE;
          end else begin
            byte_ptr <= 0;
            // A single-beat packet cannot reach byte 82
          end
        end else begin
          // Current beat + previous beat make a valid window
          stg1_valid <= 1'b1;
          stg1_window <= window;
          for (int i = 0; i < NUM_CAND; i++) begin
            stg1_p[i] <= p[i][7:0];
            stg1_msg_valid[i] <= msg_take[i];
            stg1_msg_len[i] <= msg_len[i];
          end
          if (stage0_overflow) begin
            candidate_overflow <= 1'b1;
            parser_error <= 1'b1;
          end
          // NEW: detect invalid length header
          for (int i = 0; i < NUM_CAND; i++) begin
            if (header_valid[i] && msg_len[i] == 0)
              parser_error <= 1'b1;
          end
          prev_tdata <= s_axis_tdata;
          prev_valid_bytes <= curr_valid_bytes;
          if (s_axis_tlast) begin
            is_first_beat <= 1'b1;
            byte_ptr <= 0;
          end else begin
            byte_ptr <= next_byte_ptr;
          end
        end
      end
    end
  end


  //STAGE 2 NEW - message dispatcher
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      stg2_valid <= 1'b0;
      for (int i = 0; i < NUM_CAND; i++) begin
        stg2_is_target[i] <= 1'b0;
        stg2_extracted[i] <= '0;
      end
    end else begin
      stg2_valid <= stg1_valid;
      for (int i = 0; i < NUM_CAND; i++) begin
        stg2_is_target[i] <= 1'b0;
        stg2_extracted[i] <= '0;
        if (stg1_valid && stg1_msg_valid[i]) begin
          // NEW: dispatch based on message type
          case (stg1_window[(stg1_p[i] + 32'd2)*8 +: 8])
            MSG_PLU_35, MSG_PLU_38: begin
              if (stg1_msg_len[i] >= 16'd30) begin  //deep plu layout is 30 bytes
                stg2_is_target[i] <= 1'b1;
                stg2_extracted[i].msg_type <=  stg1_window[(stg1_p[i] + 32'd2)*8 +: 8];
                stg2_extracted[i].flags <= stg1_window[(stg1_p[i] + 32'd3)*8 +: 8];
                stg2_extracted[i].timestamp <= stg1_window[(stg1_p[i] + 32'd4)*8 +: 64];
                stg2_extracted[i].symbol <= stg1_window[(stg1_p[i] + 32'd12)*8 +: 64];
                stg2_extracted[i].size <= stg1_window[(stg1_p[i] + 32'd20)*8 +: 32];
                stg2_extracted[i].price <= stg1_window[(stg1_p[i] + 32'd24)*8 +: 64];
              end
            end

            // NEW: add other message types here
            // MSG_TRADE: begin
            // end

            // MSG_TRADE_BREAK: begin
            // end

            // MSG_SYSTEM_EVENT: begin
            // end

            default: begin
              //skip unsupported msg types
            end
          endcase
        end
      end
    end
  end


  //each fifo is a row containing up to 6 decoded msgs
  (* ram_style = "distributed" *)
  market_event_t fifo_data [0:31][0:NUM_CAND-1];

  (* ram_style = "distributed" *)
  logic [2:0] fifo_cnt [0:31];

  // FIX: extra pointer bit distinguishes full from empty
  logic [5:0] wr_ptr;
  logic [5:0] rd_ptr;
  logic [5:0] fifo_occupancy;

  assign fifo_occupancy = wr_ptr - rd_ptr;

  // FIX: reserve room for in-flight pipeline rows
  assign s_axis_tready = aresetn && (fifo_occupancy < 6'd28);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wr_ptr <= '0;
    end else if (stg2_valid && pack_cnt > 0) begin
      fifo_cnt[wr_ptr[4:0]] <= pack_cnt;
      for (int i = 0; i < NUM_CAND; i++)
        fifo_data[wr_ptr[4:0]][i] <= pack_data[i];
      wr_ptr <= wr_ptr + 1;
    end
  end

  logic row_active;
  logic [2:0] pop_idx;
  logic [2:0] current_row_cnt;
  market_event_t current_row_data [0:NUM_CAND-1];

  // NEW: unpack output struct
  market_event_t output_event;

  assign {
    out_msg_type,
    out_flags,
    out_timestamp,
    out_symbol,
    out_size,
    out_price
  } = output_event;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rd_ptr <= '0;
      row_active <= 1'b0;
      pop_idx <= '0;
      current_row_cnt <= '0;
      out_valid <= 1'b0;
      output_event <= '0;
    end else begin
      out_valid <= 1'b0;
      if (row_active) begin
        output_event <= current_row_data[pop_idx];
        out_valid <= 1'b1;
        if (pop_idx == current_row_cnt - 1) begin
          row_active <= 1'b0; // Row exhausted
        end else begin
          pop_idx <= pop_idx + 1;
        end
      end else if (wr_ptr != rd_ptr) begin
        // output index 0 immediately
        output_event <= fifo_data[rd_ptr[4:0]][0];
        out_valid <= 1'b1;
        // buffer them for subsequent cycles
        if (fifo_cnt[rd_ptr[4:0]] > 1) begin
          current_row_cnt <= fifo_cnt[rd_ptr[4:0]];
          for (int i = 0; i < NUM_CAND; i++)
            current_row_data[i] <= fifo_data[rd_ptr[4:0]][i];
          row_active <= 1'b1;
          pop_idx <= 3'd1;
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