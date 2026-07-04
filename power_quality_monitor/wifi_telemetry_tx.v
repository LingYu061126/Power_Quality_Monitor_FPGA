//==============================================================================
// 模块：wifi_telemetry_tx
// 说明：
//   ESP8266 SoftAP TCP服务器遥测发送模块。
//   复位后，本模块按照STEP底板WiFi实验中的AT命令序列配置ESP8266：
//     AT+CWMODE=2
//     AT+CWSAP="STEP_FPGA","12345678",5,4
//     AT+RST
//     AT+CIPMUX=1
//     AT+CIPSERVER=1,8686
//
//   运行时网络访问参数：
//     SSID: STEP_FPGA
//     PASS: 12345678
//     TCP : 192.168.4.1:8686
//
//   串口：115200波特率，8N1格式。通过ESP8266 TCP服务器发送FPGA数据时，
//   每帧遥测负载前先发送AT+CIPSEND=0,77进行封装。
//   遥测字段G表示运行状态：G=1运行，G=0暂停。
//   N为000~999循环帧序号；C为从帧首到N字段末尾的ASCII字节异或校验。
//==============================================================================

module wifi_telemetry_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  rms_value,
    input  wire [7:0]  peak_value,
    input  wire [7:0]  freq_hz,
    input  wire [2:0]  fault_type,
    input  wire [2:0]  fault_mode,
    input  wire        freeze_active,
    input  wire        alarm_level,
    input  wire [4:0]  event_count,
    input  wire [7:0]  adc_data,
    input  wire [15:0] system_time_bcd,
    input  wire [7:0]  duration_sec,
    input  wire        system_running,
    output wire        txd
);

    localparam [27:0] BOOT_DELAY      = 28'd100000000; // 50MHz下2s
    localparam [27:0] CMD_DELAY       = 28'd50000000;  // 50MHz下1s
    localparam [27:0] RST_DELAY       = 28'd250000000; // 50MHz下5s
    localparam [27:0] PROMPT_DELAY    = 28'd5000000;   // 50MHz下100ms
    localparam [27:0] FRAME_INTERVAL  = 28'd25000000;  // 50MHz下500ms

    localparam [6:0]  FRAME_LEN       = 7'd77;
    localparam [6:0]  CIPSEND_LEN     = 7'd17;

    localparam [1:0]  KIND_BUFFER     = 2'd0;
    localparam [1:0]  KIND_FRAME      = 2'd1;

    localparam [3:0]  ST_BOOT_WAIT    = 4'd0;
    localparam [3:0]  ST_INIT_LOAD    = 4'd1;
    localparam [3:0]  ST_INIT_GAP     = 4'd2;
    localparam [3:0]  ST_RUN_WAIT     = 4'd3;
    localparam [3:0]  ST_CIPSEND_LOAD = 4'd4;
    localparam [3:0]  ST_PROMPT_WAIT  = 4'd5;
    localparam [3:0]  ST_FRAME_LOAD   = 4'd6;
    localparam [3:0]  ST_SEND_BYTE    = 4'd7;
    localparam [3:0]  ST_WAIT_BUSY    = 4'd8;
    localparam [3:0]  ST_WAIT_DONE    = 4'd9;

    reg [3:0]  state;
    reg [3:0]  return_state;
    reg [27:0] delay_cnt;
    reg [27:0] gap_target;
    reg [2:0]  init_idx;
    reg [6:0]  byte_idx;
    reg [6:0]  send_len;
    reg [1:0]  send_kind;
    reg [319:0] send_buf; // 最多40个命令字节

    reg [7:0] tx_data;
    reg       tx_start;
    wire      tx_busy;

    reg [7:0] rms_latched;
    reg [7:0] peak_latched;
    reg [7:0] freq_latched;
    reg [2:0] fault_latched;
    reg [2:0] mode_latched;
    reg       freeze_latched;
    reg       alarm_latched;
    reg [4:0] event_latched;
    reg [7:0] adc_latched;
    reg [15:0] time_latched;
    reg [7:0] duration_latched;
    reg       running_latched;
    reg [11:0] sequence_bcd;
    reg [11:0] sequence_latched;
    reg [7:0] checksum_accum;

    uart_tx u_uart_wifi (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx_busy  (tx_busy),
        .txd      (txd)
    );

    function [7:0] ascii_digit;
        input [3:0] digit;
        begin
            ascii_digit = 8'h30 + {4'b0000, digit};
        end
    endfunction

    function [7:0] ascii_hex;
        input [3:0] nibble;
        begin
            ascii_hex = (nibble < 4'd10) ?
                        (8'h30 + {4'b0000, nibble}) :
                        (8'h41 + {4'b0000, nibble - 4'd10});
        end
    endfunction

    function [11:0] bcd_inc3;
        input [11:0] value;
        begin
            if (value == 12'h999)
                bcd_inc3 = 12'h000;
            else if (value[3:0] != 4'd9)
                bcd_inc3 = {value[11:4], value[3:0] + 1'b1};
            else if (value[7:4] != 4'd9)
                bcd_inc3 = {value[11:8], value[7:4] + 1'b1, 4'd0};
            else
                bcd_inc3 = {value[11:8] + 1'b1, 8'h00};
        end
    endfunction

    function [3:0] dec_hundreds_8;
        input [7:0] value;
        begin
            if (value >= 8'd200)
                dec_hundreds_8 = 4'd2;
            else if (value >= 8'd100)
                dec_hundreds_8 = 4'd1;
            else
                dec_hundreds_8 = 4'd0;
        end
    endfunction

    function [3:0] dec_tens_8;
        input [7:0] value;
        reg [7:0] rem;
        begin
            rem = value;
            if (rem >= 8'd200)
                rem = rem - 8'd200;
            else if (rem >= 8'd100)
                rem = rem - 8'd100;

            if (rem >= 8'd90)
                dec_tens_8 = 4'd9;
            else if (rem >= 8'd80)
                dec_tens_8 = 4'd8;
            else if (rem >= 8'd70)
                dec_tens_8 = 4'd7;
            else if (rem >= 8'd60)
                dec_tens_8 = 4'd6;
            else if (rem >= 8'd50)
                dec_tens_8 = 4'd5;
            else if (rem >= 8'd40)
                dec_tens_8 = 4'd4;
            else if (rem >= 8'd30)
                dec_tens_8 = 4'd3;
            else if (rem >= 8'd20)
                dec_tens_8 = 4'd2;
            else if (rem >= 8'd10)
                dec_tens_8 = 4'd1;
            else
                dec_tens_8 = 4'd0;
        end
    endfunction

    function [3:0] dec_units_8;
        input [7:0] value;
        reg [7:0] rem;
        begin
            rem = value;
            if (rem >= 8'd200)
                rem = rem - 8'd200;
            else if (rem >= 8'd100)
                rem = rem - 8'd100;

            if (rem >= 8'd90)
                rem = rem - 8'd90;
            else if (rem >= 8'd80)
                rem = rem - 8'd80;
            else if (rem >= 8'd70)
                rem = rem - 8'd70;
            else if (rem >= 8'd60)
                rem = rem - 8'd60;
            else if (rem >= 8'd50)
                rem = rem - 8'd50;
            else if (rem >= 8'd40)
                rem = rem - 8'd40;
            else if (rem >= 8'd30)
                rem = rem - 8'd30;
            else if (rem >= 8'd20)
                rem = rem - 8'd20;
            else if (rem >= 8'd10)
                rem = rem - 8'd10;

            dec_units_8 = rem[3:0];
        end
    endfunction

    wire [3:0] rms_h   = dec_hundreds_8(rms_latched);
    wire [3:0] rms_t   = dec_tens_8(rms_latched);
    wire [3:0] rms_u   = dec_units_8(rms_latched);
    wire [3:0] peak_h  = dec_hundreds_8(peak_latched);
    wire [3:0] peak_t  = dec_tens_8(peak_latched);
    wire [3:0] peak_u  = dec_units_8(peak_latched);
    wire [3:0] freq_h  = dec_hundreds_8(freq_latched);
    wire [3:0] freq_t  = dec_tens_8(freq_latched);
    wire [3:0] freq_u  = dec_units_8(freq_latched);
    wire [3:0] event_t = dec_tens_8({3'b000, event_latched});
    wire [3:0] event_u = dec_units_8({3'b000, event_latched});
    wire [3:0] adc_h   = dec_hundreds_8(adc_latched);
    wire [3:0] adc_t   = dec_tens_8(adc_latched);
    wire [3:0] adc_u   = dec_units_8(adc_latched);
    wire [3:0] dur_h   = dec_hundreds_8(duration_latched);
    wire [3:0] dur_t   = dec_tens_8(duration_latched);
    wire [3:0] dur_u   = dec_units_8(duration_latched);

    reg [7:0] frame_byte;

    always @(*) begin
        case (byte_idx)
            6'd0:  frame_byte = "P";
            6'd1:  frame_byte = "Q";
            6'd2:  frame_byte = ",";
            6'd3:  frame_byte = "R";
            6'd4:  frame_byte = "=";
            6'd5:  frame_byte = ascii_digit(rms_h);
            6'd6:  frame_byte = ascii_digit(rms_t);
            6'd7:  frame_byte = ascii_digit(rms_u);
            6'd8:  frame_byte = ",";
            6'd9:  frame_byte = "P";
            6'd10: frame_byte = "=";
            6'd11: frame_byte = ascii_digit(peak_h);
            6'd12: frame_byte = ascii_digit(peak_t);
            6'd13: frame_byte = ascii_digit(peak_u);
            6'd14: frame_byte = ",";
            6'd15: frame_byte = "F";
            6'd16: frame_byte = "=";
            6'd17: frame_byte = ascii_digit(freq_h);
            6'd18: frame_byte = ascii_digit(freq_t);
            6'd19: frame_byte = ascii_digit(freq_u);
            6'd20: frame_byte = ",";
            6'd21: frame_byte = "T";
            6'd22: frame_byte = "=";
            6'd23: frame_byte = ascii_digit({1'b0, fault_latched});
            6'd24: frame_byte = ",";
            6'd25: frame_byte = "M";
            6'd26: frame_byte = "=";
            6'd27: frame_byte = ascii_digit({1'b0, mode_latched});
            6'd28: frame_byte = ",";
            6'd29: frame_byte = "Z";
            6'd30: frame_byte = "=";
            6'd31: frame_byte = ascii_digit({3'b000, freeze_latched});
            6'd32: frame_byte = ",";
            6'd33: frame_byte = "A";
            6'd34: frame_byte = "=";
            6'd35: frame_byte = ascii_digit({3'b000, alarm_latched});
            6'd36: frame_byte = ",";
            6'd37: frame_byte = "E";
            6'd38: frame_byte = "=";
            6'd39: frame_byte = ascii_digit(event_t);
            6'd40: frame_byte = ascii_digit(event_u);
            6'd41: frame_byte = ",";
            6'd42: frame_byte = "D";
            6'd43: frame_byte = "=";
            6'd44: frame_byte = ascii_digit(adc_h);
            6'd45: frame_byte = ascii_digit(adc_t);
            6'd46: frame_byte = ascii_digit(adc_u);
            6'd47: frame_byte = ",";
            6'd48: frame_byte = "S";
            6'd49: frame_byte = "=";
            6'd50: frame_byte = ascii_digit(time_latched[15:12]);
            6'd51: frame_byte = ascii_digit(time_latched[11:8]);
            6'd52: frame_byte = ascii_digit(time_latched[7:4]);
            6'd53: frame_byte = ascii_digit(time_latched[3:0]);
            6'd54: frame_byte = ",";
            6'd55: frame_byte = "U";
            6'd56: frame_byte = "=";
            6'd57: frame_byte = ascii_digit(dur_h);
            6'd58: frame_byte = ascii_digit(dur_t);
            6'd59: frame_byte = ascii_digit(dur_u);
            7'd60: frame_byte = ",";
            7'd61: frame_byte = "G";
            7'd62: frame_byte = "=";
            7'd63: frame_byte = ascii_digit({3'b000, running_latched});
            7'd64: frame_byte = ",";
            7'd65: frame_byte = "N";
            7'd66: frame_byte = "=";
            7'd67: frame_byte = ascii_digit(sequence_latched[11:8]);
            7'd68: frame_byte = ascii_digit(sequence_latched[7:4]);
            7'd69: frame_byte = ascii_digit(sequence_latched[3:0]);
            7'd70: frame_byte = ",";
            7'd71: frame_byte = "C";
            7'd72: frame_byte = "=";
            7'd73: frame_byte = ascii_hex(checksum_accum[7:4]);
            7'd74: frame_byte = ascii_hex(checksum_accum[3:0]);
            7'd75: frame_byte = 8'h0d;
            7'd76: frame_byte = 8'h0a;
            default: frame_byte = 8'h0a;
        endcase
    end

    wire [7:0] buffer_byte =
        send_buf[((send_len - 7'd1 - byte_idx) * 8) +: 8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_BOOT_WAIT;
            return_state   <= ST_BOOT_WAIT;
            delay_cnt      <= 28'd0;
            gap_target     <= BOOT_DELAY;
            init_idx       <= 3'd0;
            byte_idx       <= 7'd0;
            send_len       <= 7'd0;
            send_kind      <= KIND_BUFFER;
            send_buf       <= 320'd0;
            tx_data        <= 8'd0;
            tx_start       <= 1'b0;
            rms_latched    <= 8'd0;
            peak_latched   <= 8'd0;
            freq_latched   <= 8'd0;
            fault_latched  <= 3'd0;
            mode_latched   <= 3'd0;
            freeze_latched <= 1'b0;
            alarm_latched  <= 1'b0;
            event_latched  <= 5'd0;
            adc_latched    <= 8'd0;
            time_latched   <= 16'h0000;
            duration_latched <= 8'd0;
            running_latched <= 1'b0;
            sequence_bcd     <= 12'h000;
            sequence_latched <= 12'h000;
            checksum_accum   <= 8'h00;
        end else begin
            tx_start <= 1'b0;

            case (state)
                ST_BOOT_WAIT: begin
                    if (delay_cnt >= BOOT_DELAY - 28'd1) begin
                        delay_cnt <= 28'd0;
                        init_idx  <= 3'd0;
                        state     <= ST_INIT_LOAD;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                ST_INIT_LOAD: begin
                    byte_idx     <= 7'd0;
                    send_kind    <= KIND_BUFFER;
                    return_state <= ST_INIT_GAP;

                    case (init_idx)
                        3'd0: begin
                            send_buf   <= {"AT+CWMODE=2", 16'h0d0a};
                            send_len   <= 7'd13;
                            gap_target <= CMD_DELAY;
                        end
                        3'd1: begin
                            send_buf   <= {"AT+CWSAP=", 8'h22, "STEP_FPGA", 8'h22, ",", 8'h22, "12345678", 8'h22, ",5,4", 16'h0d0a};
                            send_len   <= 7'd37;
                            gap_target <= CMD_DELAY;
                        end
                        3'd2: begin
                            send_buf   <= {"AT+RST", 16'h0d0a};
                            send_len   <= 7'd8;
                            gap_target <= RST_DELAY;
                        end
                        3'd3: begin
                            send_buf   <= {"AT+CIPMUX=1", 16'h0d0a};
                            send_len   <= 7'd13;
                            gap_target <= CMD_DELAY;
                        end
                        3'd4: begin
                            send_buf   <= {"AT+CIPSERVER=1,8686", 16'h0d0a};
                            send_len   <= 7'd21;
                            gap_target <= CMD_DELAY;
                        end
                        default: begin
                            send_buf   <= 320'd0;
                            send_len   <= 7'd0;
                            gap_target <= CMD_DELAY;
                        end
                    endcase

                    state <= ST_SEND_BYTE;
                end

                ST_INIT_GAP: begin
                    if (delay_cnt >= gap_target - 28'd1) begin
                        delay_cnt <= 28'd0;
                        if (init_idx == 3'd4) begin
                            state <= ST_RUN_WAIT;
                        end else begin
                            init_idx <= init_idx + 1'b1;
                            state    <= ST_INIT_LOAD;
                        end
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                ST_RUN_WAIT: begin
                    if (delay_cnt >= FRAME_INTERVAL - 28'd1) begin
                        delay_cnt      <= 28'd0;
                        rms_latched    <= rms_value;
                        peak_latched   <= peak_value;
                        freq_latched   <= freq_hz;
                        fault_latched  <= fault_type;
                        mode_latched   <= fault_mode;
                        freeze_latched <= freeze_active;
                        alarm_latched  <= alarm_level;
                        event_latched  <= event_count;
                        adc_latched    <= adc_data;
                        time_latched   <= system_time_bcd;
                        duration_latched <= duration_sec;
                        running_latched <= system_running;
                        sequence_latched <= sequence_bcd;
                        sequence_bcd     <= bcd_inc3(sequence_bcd);
                        state          <= ST_CIPSEND_LOAD;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                ST_CIPSEND_LOAD: begin
                    send_buf     <= {"AT+CIPSEND=0,77", 16'h0d0a};
                    send_len     <= CIPSEND_LEN;
                    send_kind    <= KIND_BUFFER;
                    byte_idx     <= 7'd0;
                    return_state <= ST_PROMPT_WAIT;
                    state        <= ST_SEND_BYTE;
                end

                ST_PROMPT_WAIT: begin
                    if (delay_cnt >= PROMPT_DELAY - 28'd1) begin
                        delay_cnt <= 28'd0;
                        state     <= ST_FRAME_LOAD;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                ST_FRAME_LOAD: begin
                    send_len     <= FRAME_LEN;
                    send_kind    <= KIND_FRAME;
                    byte_idx     <= 7'd0;
                    checksum_accum <= 8'h00;
                    return_state <= ST_RUN_WAIT;
                    state        <= ST_SEND_BYTE;
                end

                ST_SEND_BYTE: begin
                    if (!tx_busy) begin
                        tx_data  <= (send_kind == KIND_FRAME) ? frame_byte : buffer_byte;
                        tx_start <= 1'b1;
                        if (send_kind == KIND_FRAME && byte_idx <= 7'd69)
                            checksum_accum <= checksum_accum ^ frame_byte;
                        state    <= ST_WAIT_BUSY;
                    end
                end

                ST_WAIT_BUSY: begin
                    state <= ST_WAIT_DONE;
                end

                ST_WAIT_DONE: begin
                    if (!tx_busy) begin
                        if (byte_idx == send_len - 7'd1) begin
                            byte_idx <= 7'd0;
                            state    <= return_state;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= ST_SEND_BYTE;
                        end
                    end
                end

                default: begin
                    state     <= ST_BOOT_WAIT;
                    delay_cnt <= 28'd0;
                end
            endcase
        end
    end

endmodule
