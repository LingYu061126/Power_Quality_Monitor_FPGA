// 由tools/build_ui_template.py根据logo.png自动生成。
// LCD坐标系：横屏320x240。
// 标签由Times New Roman（times.ttf）栅格化生成。
//
// 可修改区域：
//   STATUS   : x=7..254, y=7..68   (x=255..314用于标志)
//   PARAMETER: x=7..317, y=70..112
//   WAVE     : x=7..317, y=114..232
//
// 修改student_status_pixel()可添加状态文字/图标。
// 修改student_parameter_pixel()可添加参数文字/图标。
// 修改student_wave_pixel()可绘制波形。
module ui_template (
    input  wire [8:0]  x,
    input  wire [8:0]  y,
    input  wire [2:0]  fault_type,
    input  wire [7:0]  rms_value,
    input  wire [7:0]  peak_value,
    input  wire [7:0]  freq_value,
    input  wire [4:0]  event_count,
    input  wire [15:0] display_time_bcd,
    input  wire        display_time_is_fault,
    input  wire        system_running,
    input  wire        freeze_active,
    output reg  [15:0] rgb565
);

localparam [15:0] COLOR_WHITE = 16'hFFFF;
localparam [15:0] COLOR_BLACK = 16'h0000;
localparam [15:0] COLOR_LOGO  = 16'hB142; // 从logo.png采样得到的前景色
localparam [15:0] COLOR_RED     = 16'hF800;
localparam [15:0] COLOR_GREEN   = 16'h07E0;
localparam [15:0] COLOR_BLUE    = 16'h001F;
localparam [15:0] COLOR_MAGENTA = 16'hF81F;

localparam [8:0] UI_X0 = 9'd6;
localparam [8:0] UI_X1 = 9'd318;
localparam [8:0] UI_Y0 = 9'd6;
localparam [8:0] UI_Y1 = 9'd233;
localparam [8:0] STATUS_DIVIDER_Y = 9'd69;
localparam [8:0] PARAMETER_DIVIDER_Y = 9'd113;

localparam [8:0] LOGO_X = 9'd255;
localparam [8:0] LOGO_Y = 9'd7;
localparam [8:0] LOGO_SIZE = 9'd60;

localparam [8:0] STATUS_LABEL_X = 9'd12;
localparam [8:0] STATUS_LABEL_Y = 9'd11;
localparam [8:0] STATUS_LABEL_W = 9'd64;
localparam [8:0] STATUS_LABEL_H = 9'd16;
localparam [8:0] PARAMETER_LABEL_X = 9'd12;
localparam [8:0] PARAMETER_LABEL_Y = 9'd74;
localparam [8:0] PARAMETER_LABEL_W = 9'd111;
localparam [8:0] PARAMETER_LABEL_H = 9'd22;
localparam [8:0] WAVE_LABEL_X = 9'd12;
localparam [8:0] WAVE_LABEL_Y = 9'd118;
localparam [8:0] WAVE_LABEL_W = 9'd58;
localparam [8:0] WAVE_LABEL_H = 9'd12;

wire border_pixel =
    ((x >= UI_X0 && x <= UI_X1) &&
     (y == UI_Y0 || y == STATUS_DIVIDER_Y || y == PARAMETER_DIVIDER_Y || y == UI_Y1)) ||
    ((y >= UI_Y0 && y <= UI_Y1) && (x == UI_X0 || x == UI_X1));

wire logo_area =
    (x >= LOGO_X) && (x < LOGO_X + LOGO_SIZE) &&
    (y >= LOGO_Y) && (y < LOGO_Y + LOGO_SIZE);
wire [8:0] logo_col_full = x - LOGO_X;
wire [8:0] logo_line_full = y - LOGO_Y;
wire [5:0] logo_col = logo_col_full[5:0];
wire [5:0] logo_line = logo_line_full[5:0];
wire [59:0] logo_bits = logo_row(logo_line);
wire logo_pixel = logo_area && logo_bits[logo_col];

wire status_label_area =
    (x >= STATUS_LABEL_X) && (x < STATUS_LABEL_X + STATUS_LABEL_W) &&
    (y >= STATUS_LABEL_Y) && (y < STATUS_LABEL_Y + STATUS_LABEL_H);
wire [8:0] status_label_col = x - STATUS_LABEL_X;
wire [8:0] status_label_line_full = y - STATUS_LABEL_Y;
wire [5:0] status_label_line = status_label_line_full[5:0];
wire [63:0] status_label_bits = status_label_row(status_label_line);
wire status_label_pixel = status_label_area && status_label_bits[status_label_col];

wire parameter_label_area =
    (x >= PARAMETER_LABEL_X) && (x < PARAMETER_LABEL_X + PARAMETER_LABEL_W) &&
    (y >= PARAMETER_LABEL_Y) && (y < PARAMETER_LABEL_Y + PARAMETER_LABEL_H);
wire [8:0] parameter_label_col = x - PARAMETER_LABEL_X;
wire [8:0] parameter_label_line_full = y - PARAMETER_LABEL_Y;
wire [5:0] parameter_label_line = parameter_label_line_full[5:0];
wire [110:0] parameter_label_bits = parameter_label_row(parameter_label_line);
wire parameter_label_pixel = parameter_label_area && parameter_label_bits[parameter_label_col];

wire wave_label_area =
    (x >= WAVE_LABEL_X) && (x < WAVE_LABEL_X + WAVE_LABEL_W) &&
    (y >= WAVE_LABEL_Y) && (y < WAVE_LABEL_Y + WAVE_LABEL_H);
wire [8:0] wave_label_col = x - WAVE_LABEL_X;
wire [8:0] wave_label_line_full = y - WAVE_LABEL_Y;
wire [5:0] wave_label_line = wave_label_line_full[5:0];
wire [57:0] wave_label_bits = wave_label_row(wave_label_line);
wire wave_label_pixel = wave_label_area && wave_label_bits[wave_label_col];

wire label_pixel = status_label_pixel || parameter_label_pixel || wave_label_pixel;
wire status_pixel = student_status_pixel(x, y);
wire parameter_pixel = student_parameter_pixel(x, y);
wire wave_pixel = student_wave_pixel(x, y);

function [3:0] dec_hundreds;
    input [7:0] val;
    begin
        if (val >= 8'd200)
            dec_hundreds = 4'd2;
        else if (val >= 8'd100)
            dec_hundreds = 4'd1;
        else
            dec_hundreds = 4'd0;
    end
endfunction

function [3:0] dec_tens;
    input [7:0] val;
    reg [7:0] rem;
    begin
        if (val >= 8'd200)
            rem = val - 8'd200;
        else if (val >= 8'd100)
            rem = val - 8'd100;
        else
            rem = val;

        if (rem >= 8'd90)      dec_tens = 4'd9;
        else if (rem >= 8'd80) dec_tens = 4'd8;
        else if (rem >= 8'd70) dec_tens = 4'd7;
        else if (rem >= 8'd60) dec_tens = 4'd6;
        else if (rem >= 8'd50) dec_tens = 4'd5;
        else if (rem >= 8'd40) dec_tens = 4'd4;
        else if (rem >= 8'd30) dec_tens = 4'd3;
        else if (rem >= 8'd20) dec_tens = 4'd2;
        else if (rem >= 8'd10) dec_tens = 4'd1;
        else                   dec_tens = 4'd0;
    end
endfunction

function [3:0] dec_units;
    input [7:0] val;
    reg [7:0] rem;
    begin
        if (val >= 8'd200)
            rem = val - 8'd200;
        else if (val >= 8'd100)
            rem = val - 8'd100;
        else
            rem = val;

        if (rem >= 8'd90)      rem = rem - 8'd90;
        else if (rem >= 8'd80) rem = rem - 8'd80;
        else if (rem >= 8'd70) rem = rem - 8'd70;
        else if (rem >= 8'd60) rem = rem - 8'd60;
        else if (rem >= 8'd50) rem = rem - 8'd50;
        else if (rem >= 8'd40) rem = rem - 8'd40;
        else if (rem >= 8'd30) rem = rem - 8'd30;
        else if (rem >= 8'd20) rem = rem - 8'd20;
        else if (rem >= 8'd10) rem = rem - 8'd10;

        dec_units = rem[3:0];
    end
endfunction

// 频率数字（freq_value已是Hz）
wire [7:0] freq_hz    = freq_value;
wire [3:0] freq_hund  = dec_hundreds(freq_hz);
wire [3:0] freq_ten   = dec_tens(freq_hz);
wire [3:0] freq_unit  = dec_units(freq_hz);

// 状态条：保持原始位置，颜色由fault_type决定
wire fault_bar_pixel = (y >= 9'd30 && y < 9'd37 && x >= 9'd10 && x < 9'd80);
wire [15:0] fault_bar_color;
assign fault_bar_color = (fault_type == 3'b000) ? COLOR_GREEN :
                         ((fault_type == 3'b001) || (fault_type == 3'b010)) ? COLOR_BLUE :
                         ((fault_type == 3'b011) || (fault_type == 3'b100)) ? COLOR_RED :
                         ((fault_type == 3'b101) || (fault_type == 3'b110)) ? COLOR_MAGENTA : COLOR_WHITE;

always @(*) begin
    if (fault_bar_pixel)
        rgb565 = fault_bar_color;
    else if (border_pixel || label_pixel || status_pixel || parameter_pixel || wave_pixel)
        rgb565 = COLOR_BLACK;
    else if (logo_pixel)
        rgb565 = COLOR_LOGO;
    else
        rgb565 = COLOR_WHITE;
end

//##############################################################################
// 动态文本用5x7点阵字体辅助函数
//##############################################################################
function [4:0] digit_5x7;
    input [3:0] digit;
    input [2:0] row;
    begin
        digit_5x7 = 5'b00000;
        case (digit)
            4'h0: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10011; 3'd3: digit_5x7=5'b10101; 3'd4: digit_5x7=5'b11001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h1: case(row) 3'd0: digit_5x7=5'b00100; 3'd1: digit_5x7=5'b01100; 3'd2: digit_5x7=5'b00100; 3'd3: digit_5x7=5'b00100; 3'd4: digit_5x7=5'b00100; 3'd5: digit_5x7=5'b00100; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h2: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b00001; 3'd3: digit_5x7=5'b00010; 3'd4: digit_5x7=5'b00100; 3'd5: digit_5x7=5'b01000; 3'd6: digit_5x7=5'b11111; default: digit_5x7=5'b00000; endcase
            4'h3: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b00001; 3'd3: digit_5x7=5'b00110; 3'd4: digit_5x7=5'b00001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h4: case(row) 3'd0: digit_5x7=5'b00010; 3'd1: digit_5x7=5'b00110; 3'd2: digit_5x7=5'b01010; 3'd3: digit_5x7=5'b10010; 3'd4: digit_5x7=5'b11111; 3'd5: digit_5x7=5'b00010; 3'd6: digit_5x7=5'b00010; default: digit_5x7=5'b00000; endcase
            4'h5: case(row) 3'd0: digit_5x7=5'b11111; 3'd1: digit_5x7=5'b10000; 3'd2: digit_5x7=5'b11110; 3'd3: digit_5x7=5'b00001; 3'd4: digit_5x7=5'b00001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h6: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10000; 3'd3: digit_5x7=5'b11110; 3'd4: digit_5x7=5'b10001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h7: case(row) 3'd0: digit_5x7=5'b11111; 3'd1: digit_5x7=5'b00001; 3'd2: digit_5x7=5'b00010; 3'd3: digit_5x7=5'b00100; 3'd4: digit_5x7=5'b01000; 3'd5: digit_5x7=5'b01000; 3'd6: digit_5x7=5'b01000; default: digit_5x7=5'b00000; endcase
            4'h8: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10001; 3'd3: digit_5x7=5'b01110; 3'd4: digit_5x7=5'b10001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'h9: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10001; 3'd3: digit_5x7=5'b01111; 3'd4: digit_5x7=5'b00001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'hA: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10001; 3'd3: digit_5x7=5'b11111; 3'd4: digit_5x7=5'b10001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b10001; default: digit_5x7=5'b00000; endcase
            4'hB: case(row) 3'd0: digit_5x7=5'b11110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10001; 3'd3: digit_5x7=5'b11110; 3'd4: digit_5x7=5'b10001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b11110; default: digit_5x7=5'b00000; endcase
            4'hC: case(row) 3'd0: digit_5x7=5'b01110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10000; 3'd3: digit_5x7=5'b10000; 3'd4: digit_5x7=5'b10000; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b01110; default: digit_5x7=5'b00000; endcase
            4'hD: case(row) 3'd0: digit_5x7=5'b11110; 3'd1: digit_5x7=5'b10001; 3'd2: digit_5x7=5'b10001; 3'd3: digit_5x7=5'b10001; 3'd4: digit_5x7=5'b10001; 3'd5: digit_5x7=5'b10001; 3'd6: digit_5x7=5'b11110; default: digit_5x7=5'b00000; endcase
            4'hE: case(row) 3'd0: digit_5x7=5'b11111; 3'd1: digit_5x7=5'b10000; 3'd2: digit_5x7=5'b10000; 3'd3: digit_5x7=5'b11110; 3'd4: digit_5x7=5'b10000; 3'd5: digit_5x7=5'b10000; 3'd6: digit_5x7=5'b11111; default: digit_5x7=5'b00000; endcase
            4'hF: case(row) 3'd0: digit_5x7=5'b11111; 3'd1: digit_5x7=5'b10000; 3'd2: digit_5x7=5'b10000; 3'd3: digit_5x7=5'b11110; 3'd4: digit_5x7=5'b10000; 3'd5: digit_5x7=5'b10000; 3'd6: digit_5x7=5'b10000; default: digit_5x7=5'b00000; endcase
        endcase
    end
endfunction

function [4:0] letter_5x7;
    input [7:0] ch;
    input [2:0] row;
    begin
        letter_5x7 = 5'b00000;
        case (ch)
            "A": case(row) 3'd0: letter_5x7=5'b01110; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b11111; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "E": case(row) 3'd0: letter_5x7=5'b11111; 3'd1: letter_5x7=5'b10000; 3'd2: letter_5x7=5'b10000; 3'd3: letter_5x7=5'b11110; 3'd4: letter_5x7=5'b10000; 3'd5: letter_5x7=5'b10000; 3'd6: letter_5x7=5'b11111; default: letter_5x7=5'b00000; endcase
            "F": case(row) 3'd0: letter_5x7=5'b11111; 3'd1: letter_5x7=5'b10000; 3'd2: letter_5x7=5'b10000; 3'd3: letter_5x7=5'b11110; 3'd4: letter_5x7=5'b10000; 3'd5: letter_5x7=5'b10000; 3'd6: letter_5x7=5'b10000; default: letter_5x7=5'b00000; endcase
            "H": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b11111; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "K": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b10010; 3'd2: letter_5x7=5'b10100; 3'd3: letter_5x7=5'b11000; 3'd4: letter_5x7=5'b10100; 3'd5: letter_5x7=5'b10010; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "L": case(row) 3'd0: letter_5x7=5'b10000; 3'd1: letter_5x7=5'b10000; 3'd2: letter_5x7=5'b10000; 3'd3: letter_5x7=5'b10000; 3'd4: letter_5x7=5'b10000; 3'd5: letter_5x7=5'b10000; 3'd6: letter_5x7=5'b11111; default: letter_5x7=5'b00000; endcase
            "M": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b11011; 3'd2: letter_5x7=5'b10101; 3'd3: letter_5x7=5'b10101; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "N": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b11001; 3'd2: letter_5x7=5'b10101; 3'd3: letter_5x7=5'b10011; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "O": case(row) 3'd0: letter_5x7=5'b01110; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b10001; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b01110; default: letter_5x7=5'b00000; endcase
            "P": case(row) 3'd0: letter_5x7=5'b11110; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b11110; 3'd4: letter_5x7=5'b10000; 3'd5: letter_5x7=5'b10000; 3'd6: letter_5x7=5'b10000; default: letter_5x7=5'b00000; endcase
            "Q": case(row) 3'd0: letter_5x7=5'b01110; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b10001; 3'd4: letter_5x7=5'b10101; 3'd5: letter_5x7=5'b10010; 3'd6: letter_5x7=5'b01101; default: letter_5x7=5'b00000; endcase
            "R": case(row) 3'd0: letter_5x7=5'b11110; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b11110; 3'd4: letter_5x7=5'b10100; 3'd5: letter_5x7=5'b10010; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "S": case(row) 3'd0: letter_5x7=5'b01111; 3'd1: letter_5x7=5'b10000; 3'd2: letter_5x7=5'b10000; 3'd3: letter_5x7=5'b01110; 3'd4: letter_5x7=5'b00001; 3'd5: letter_5x7=5'b00001; 3'd6: letter_5x7=5'b11110; default: letter_5x7=5'b00000; endcase
            "T": case(row) 3'd0: letter_5x7=5'b11111; 3'd1: letter_5x7=5'b00100; 3'd2: letter_5x7=5'b00100; 3'd3: letter_5x7=5'b00100; 3'd4: letter_5x7=5'b00100; 3'd5: letter_5x7=5'b00100; 3'd6: letter_5x7=5'b00100; default: letter_5x7=5'b00000; endcase
            "U": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b10001; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b10001; 3'd6: letter_5x7=5'b01110; default: letter_5x7=5'b00000; endcase
            "V": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b10001; 3'd4: letter_5x7=5'b10001; 3'd5: letter_5x7=5'b01010; 3'd6: letter_5x7=5'b00100; default: letter_5x7=5'b00000; endcase
            "W": case(row) 3'd0: letter_5x7=5'b10001; 3'd1: letter_5x7=5'b10001; 3'd2: letter_5x7=5'b10001; 3'd3: letter_5x7=5'b10101; 3'd4: letter_5x7=5'b10101; 3'd5: letter_5x7=5'b11011; 3'd6: letter_5x7=5'b10001; default: letter_5x7=5'b00000; endcase
            "Z": case(row) 3'd0: letter_5x7=5'b11111; 3'd1: letter_5x7=5'b00001; 3'd2: letter_5x7=5'b00010; 3'd3: letter_5x7=5'b00100; 3'd4: letter_5x7=5'b01000; 3'd5: letter_5x7=5'b10000; 3'd6: letter_5x7=5'b11111; default: letter_5x7=5'b00000; endcase
            default: letter_5x7 = 5'b00000;
        endcase
    end
endfunction

function draw_char;
    input [8:0] px;
    input [8:0] py;
    input [8:0] x0;
    input [8:0] y0;
    input [7:0] ch;
    reg [4:0] col;
    reg [2:0] row;
    reg [4:0] row_dots;
    reg [8:0] dx;
    reg [8:0] dy;
    begin
        draw_char = 1'b0;
        col = 5'd0;
        row = 3'd0;
        row_dots = 5'd0;
        dx = 9'd0;
        dy = 9'd0;
        if (py >= y0 && py < y0 + 9'd7 && px >= x0 && px < x0 + 9'd5) begin
            dy = py - y0;
            dx = px - x0;
            row = dy[2:0];
            col = 5'd4 - dx[4:0];
            row_dots = letter_5x7(ch, row);
            draw_char = row_dots[col];
        end
    end
endfunction

function draw_digit;
    input [8:0] px;
    input [8:0] py;
    input [8:0] x0;
    input [8:0] y0;
    input [3:0] digit;
    reg [4:0] col;
    reg [2:0] row;
    reg [4:0] row_dots;
    reg [8:0] dx;
    reg [8:0] dy;
    begin
        draw_digit = 1'b0;
        col = 5'd0;
        row = 3'd0;
        row_dots = 5'd0;
        dx = 9'd0;
        dy = 9'd0;
        if (py >= y0 && py < y0 + 9'd7 && px >= x0 && px < x0 + 9'd5) begin
            dy = py - y0;
            dx = px - x0;
            row = dy[2:0];
            col = 5'd4 - dx[4:0];
            row_dots = digit_5x7(digit, row);
            draw_digit = row_dots[col];
        end
    end
endfunction

// --------------------------------------------------------------------
// 可修改区域：STATUS。
// 在x=7..254、y=7..68内添加状态标记/文字。
// --------------------------------------------------------------------
function student_status_pixel;
    input [8:0] px;
    input [8:0] py;
    begin
        student_status_pixel = 1'b0;

        // 时间显示：T为系统运行秒数，F为冻结/回放的故障发生秒数。
        if (draw_char(px, py, 9'd86, 9'd12, display_time_is_fault ? "F" : "T")) student_status_pixel = 1'b1;
        if (draw_digit(px, py, 9'd98, 9'd12, display_time_bcd[15:12])) student_status_pixel = 1'b1;
        if (draw_digit(px, py, 9'd104, 9'd12, display_time_bcd[11:8])) student_status_pixel = 1'b1;
        if (draw_digit(px, py, 9'd110, 9'd12, display_time_bcd[7:4]))  student_status_pixel = 1'b1;
        if (draw_digit(px, py, 9'd116, 9'd12, display_time_bcd[3:0]))  student_status_pixel = 1'b1;

        // 暂停时在运行时间右侧显示STOP。
        if (!system_running) begin
            if (draw_char(px, py, 9'd128, 9'd12, "S")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd134, 9'd12, "T")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd140, 9'd12, "O")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd146, 9'd12, "P")) student_status_pixel = 1'b1;
        end

        // 状态区右上角的FREEZE/RUN指示
        if (system_running && freeze_active) begin
            if (draw_char(px, py, 9'd200, 9'd30, "F")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd206, 9'd30, "R")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd212, 9'd30, "E")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd218, 9'd30, "E")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd224, 9'd30, "Z")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd230, 9'd30, "E")) student_status_pixel = 1'b1;
        end else if (system_running) begin
            if (draw_char(px, py, 9'd200, 9'd30, "R")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd206, 9'd30, "U")) student_status_pixel = 1'b1;
            if (draw_char(px, py, 9'd212, 9'd30, "N")) student_status_pixel = 1'b1;
        end

        // 状态条下方显示故障类型代码"FLT"和数字
        if (draw_char(px, py, 9'd120, 9'd30, "F")) student_status_pixel = 1'b1;
        if (draw_char(px, py, 9'd126, 9'd30, "L")) student_status_pixel = 1'b1;
        if (draw_char(px, py, 9'd132, 9'd30, "T")) student_status_pixel = 1'b1;
        if (draw_digit(px, py, 9'd120, 9'd38, {1'b0, fault_type})) student_status_pixel = 1'b1;

    end
endfunction

// --------------------------------------------------------------------
// 可修改区域：PARAMETER。
// 在x=7..317、y=70..112内添加参数标记/文字。
// --------------------------------------------------------------------
function student_parameter_pixel;
    input [8:0] px;
    input [8:0] py;
    begin
        student_parameter_pixel = 1'b0;

        // RMS标签和值（十六进制）
        if (draw_char(px, py, 9'd140, 9'd83, "R")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd146, 9'd83, "M")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd152, 9'd83, "S")) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd140, 9'd91, rms_value[7:4])) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd146, 9'd91, rms_value[3:0])) student_parameter_pixel = 1'b1;

        // FREQ标签和值（十进制Hz）
        if (draw_char(px, py, 9'd180, 9'd83, "F")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd186, 9'd83, "R")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd192, 9'd83, "E")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd198, 9'd83, "Q")) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd180, 9'd91, freq_hund)) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd186, 9'd91, freq_ten )) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd192, 9'd91, freq_unit)) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd202, 9'd91, "H")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd208, 9'd91, "Z")) student_parameter_pixel = 1'b1;

        // PEAK标签和值（十六进制）
        if (draw_char(px, py, 9'd235, 9'd83, "P")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd241, 9'd83, "E")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd247, 9'd83, "A")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd253, 9'd83, "K")) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd235, 9'd91, peak_value[7:4])) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd241, 9'd91, peak_value[3:0])) student_parameter_pixel = 1'b1;

        // EVT标签和值（十六进制）
        if (draw_char(px, py, 9'd275, 9'd83, "E")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd281, 9'd83, "V")) student_parameter_pixel = 1'b1;
        if (draw_char(px, py, 9'd287, 9'd83, "T")) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd275, 9'd91, {3'b0, event_count[4]})) student_parameter_pixel = 1'b1;
        if (draw_digit(px, py, 9'd281, 9'd91, event_count[3:0])) student_parameter_pixel = 1'b1;
    end
endfunction

// --------------------------------------------------------------------
// 可修改区域：WAVE。
// 实际波形由lcd_show_pic叠加，此处保持空白。
// --------------------------------------------------------------------
function student_wave_pixel;
    input [8:0] px;
    input [8:0] py;
    begin
        student_wave_pixel = 1'b0;
    end
endfunction

function [63:0] status_label_row;
    input [5:0] row;
    reg [63:0] row_bits;
    begin
        case (row)
            6'd0 : row_bits = 64'h0000000800008000;
            6'd1 : row_bits = 64'h0000000C0000C000;
            6'd2 : row_bits = 64'h0000000E0000E000;
            6'd3 : row_bits = 64'h0000000F0000F000;
            6'd4 : row_bits = 64'h3F07C7BF8FC3F9F8;
            6'd5 : row_bits = 64'h3987070E1C60E1CC;
            6'd6 : row_bits = 64'h30C7060E1C70E186;
            6'd7 : row_bits = 64'h20C7060E1C70E106;
            6'd8 : row_bits = 64'h03C7060E1E00E01E;
            6'd9 : row_bits = 64'h0F87060E1F80E07C;
            6'd10: row_bits = 64'h3E07060E1CE0E1F0;
            6'd11: row_bits = 64'h3807060E1C70E1C0;
            6'd12: row_bits = 64'h70470E0E1C30E382;
            6'd13: row_bits = 64'h70C78E0E5C70E386;
            6'd14: row_bits = 64'h31CF7E3E7FF3E18E;
            6'd15: row_bits = 64'h1FC73C1C39E1C0FE;
            default: row_bits = 64'h0;
        endcase
        status_label_row = row_bits;
    end
endfunction

function [110:0] parameter_label_row;
    input [5:0] row;
    reg [110:0] row_bits;
    begin
        case (row)
            6'd0 : row_bits = 111'h0000002000000000000000000000;
            6'd1 : row_bits = 111'h0000003000000000000000000000;
            6'd2 : row_bits = 111'h0000003800000000000000000000;
            6'd3 : row_bits = 111'h0000003C00000000000000000000;
            6'd4 : row_bits = 111'h3B83E0FE3E03C79C1F8EE0FC0798;
            6'd5 : row_bits = 111'h3FE730387307F7FF38CFF9C60FDE;
            6'd6 : row_bits = 111'h338E1838E1871E1C38ECE1C71E78;
            6'd7 : row_bits = 111'h038E0C38E0C60E1C38E0E1C71C38;
            6'd8 : row_bits = 111'h038FFC38FFC60E1C3C00E1E03818;
            6'd9 : row_bits = 111'h03800C3800C60E1C3F00E1F83818;
            6'd10: row_bits = 111'h03800C3800C60E1C39C0E1CE3818;
            6'd11: row_bits = 111'h03881C3881C60E1C38E0E1C73818;
            6'd12: row_bits = 111'h03881C3881C60E1C3860E1C31818;
            6'd13: row_bits = 111'h038EF838EF860E1CB8E0E5C71C38;
            6'd14: row_bits = 111'h0387F8F87F8F0E1CFFE0E7FF0E78;
            6'd15: row_bits = 111'h0FE3E0703E1FBFFF73C3FB9E07F8;
            6'd16: row_bits = 111'h0000000000000000000000000018;
            6'd17: row_bits = 111'h0000000000000000000000000018;
            6'd18: row_bits = 111'h0000000000000000000000000018;
            6'd19: row_bits = 111'h0000000000000000000000000018;
            6'd20: row_bits = 111'h000000000000000000000000003C;
            6'd21: row_bits = 111'h000000000000000000000000007E;
            default: row_bits = 111'h0;
        endcase
        parameter_label_row = row_bits;
    end
endfunction

function [57:0] wave_label_row;
    input [5:0] row;
    reg [57:0] row_bits;
    begin
        case (row)
            6'd0 : row_bits = 58'h07C1E3F1F879F9F;
            6'd1 : row_bits = 58'h0E60C1E38C70F0E;
            6'd2 : row_bits = 58'h1C30C1C38E3061C;
            6'd3 : row_bits = 58'h1C1841838E10E1C;
            6'd4 : row_bits = 58'h1FF86383C018E18;
            6'd5 : row_bits = 58'h00182383F009F38;
            6'd6 : row_bits = 58'h001837039C09938;
            6'd7 : row_bits = 58'h103817038E0F9F0;
            6'd8 : row_bits = 58'h10381E0386078F0;
            6'd9 : row_bits = 58'h1DF01E0B8E070E0;
            6'd10: row_bits = 58'h0FF00C0FFE03060;
            6'd11: row_bits = 58'h07C00C073C02040;
            default: row_bits = 58'h0;
        endcase
        wave_label_row = row_bits;
    end
endfunction

function [59:0] logo_row;
    input [5:0] row;
    begin
        case (row)
            6'd0 : logo_row = 60'h000000000000000;
            6'd1 : logo_row = 60'h000001FFF000000;
            6'd2 : logo_row = 60'h00000FE07F00000;
            6'd3 : logo_row = 60'h00007C0003C0000;
            6'd4 : logo_row = 60'h0001E00000F0000;
            6'd5 : logo_row = 60'h000380000618000;
            6'd6 : logo_row = 60'h000E2000040E000;
            6'd7 : logo_row = 60'h001C3C000303000;
            6'd8 : logo_row = 60'h003038000B81800;
            6'd9 : logo_row = 60'h00600C000B00C00;
            6'd10: logo_row = 60'h00C012000100600;
            6'd11: logo_row = 60'h018010FFF100300;
            6'd12: logo_row = 60'h030007C03C00180;
            6'd13: logo_row = 60'h02000C0007000C0;
            6'd14: logo_row = 60'h060038000180C40;
            6'd15: logo_row = 60'h0C00603B80C1E60;
            6'd16: logo_row = 60'h0C00C01F0021A20;
            6'd17: logo_row = 60'h180180318010F30;
            6'd18: logo_row = 60'h124300318018F10;
            6'd19: logo_row = 60'h3786003B800C518;
            6'd20: logo_row = 60'h37E4003F8004388;
            6'd21: logo_row = 60'h216C003FC00630C;
            6'd22: logo_row = 60'h600801FFF00200C;
            6'd23: logo_row = 60'h601803FFF80300C;
            6'd24: logo_row = 60'h601803FFF801004;
            6'd25: logo_row = 60'h401003FBF801004;
            6'd26: logo_row = 60'h401003FBF801806;
            6'd27: logo_row = 60'h403003FBF801806;
            6'd28: logo_row = 60'h403003FBF801806;
            6'd29: logo_row = 60'h403003FBB8019A6;
            6'd30: logo_row = 60'hCF3003FBB8018C6;
            6'd31: logo_row = 60'h433003FBB8018E6;
            6'd32: logo_row = 60'h401003FBB801806;
            6'd33: logo_row = 60'h409003BBB8019C6;
            6'd34: logo_row = 60'h679003BBBC011E4;
            6'd35: logo_row = 60'h669803BBBC01004;
            6'd36: logo_row = 60'h600803BBBC0338C;
            6'd37: logo_row = 60'h20C807BBBC023CC;
            6'd38: logo_row = 60'h33CC07BBBC06448;
            6'd39: logo_row = 60'h330607BFBC04018;
            6'd40: logo_row = 60'h108207BFBC0CC18;
            6'd41: logo_row = 60'h19F30F9F3E18710;
            6'd42: logo_row = 60'h186180000031B30;
            6'd43: logo_row = 60'h0C88C0000060E20;
            6'd44: logo_row = 60'h041C600000C6660;
            6'd45: logo_row = 60'h063E18FF43830C0;
            6'd46: logo_row = 60'h031C08FF4009080;
            6'd47: logo_row = 60'h0198C0004025180;
            6'd48: logo_row = 60'h0181C0000030300;
            6'd49: logo_row = 60'h00C38C000330600;
            6'd50: logo_row = 60'h00611D000330C00;
            6'd51: logo_row = 60'h00383318C601800;
            6'd52: logo_row = 60'h000C0338C207000;
            6'd53: logo_row = 60'h00070360C00C000;
            6'd54: logo_row = 60'h000380488038000;
            6'd55: logo_row = 60'h0000F00000E0000;
            6'd56: logo_row = 60'h00003E000F80000;
            6'd57: logo_row = 60'h000007FFFE00000;
            6'd58: logo_row = 60'h0000007FE000000;
            6'd59: logo_row = 60'h000000000000000;
            default: logo_row = 60'h000000000000000;
        endcase
    end
endfunction

endmodule
