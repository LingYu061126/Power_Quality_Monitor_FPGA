//==============================================================================
// 模块：power_quality_monitor
// 说明：电能质量监测与故障记录系统顶层模块
//   硬件平台：STEP BaseBoard V4.0 + MAX10 10M08SAM
//   功能：完成各子模块例化与系统级连接
//==============================================================================

module power_quality_monitor (
    input  wire        clk_12m,
    input  wire        rst_n,
    // ADC081S101 模数转换接口
    input  wire        adc_sdata,
    output wire        adc_cs_n,
    output wire        adc_sclk,
    // DAC081S101 数模转换接口
    output wire        dac_sync_n,
    output wire        dac_sclk,
    output wire        dac_sdi,
    // 74HC595 八位数码管接口
    output wire        rck_595,
    output wire        sclk_595,
    output wire        din_595,
    // 2.4 英寸 SPI RGB LCD（ST7789V 框架）
    output wire        lcd_dc,
    output wire        lcd_rst,
    output wire        lcd_blk,
    output wire        lcd_cs,
    output wire        lcd_mosi,
    output wire        lcd_sclk,
    // LED 指示灯
    output wire [7:0]  led,
    // 拨码开关
    input  wire [3:0]  sw,
    // 独立按键（KEY1作为rst_n，KEY2解除冻结，KEY3校准ADC零点，KEY4启停运行）
    input  wire        key2,
    input  wire        key3,
    input  wire        key4,
    // 4x4 矩阵键盘
    output wire [3:0]  row,
    input  wire [3:0]  col,
    // 蜂鸣器
    output wire        buzzer,
    // I2C 总线（AT24C02）
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,
    // UART CH340（按底板外设信号名命名：CH340 TXD/RXD）
    input  wire        txd_ch340,
    output wire        rxd_ch340,
    // UART WiFi（按底板外设信号名命名：ESP8266 TXD/RXD）
    input  wire        txd_wifi,
    output wire        rxd_wifi
	 
);


    //==========================================================================
    // 1. 时钟与复位
    //==========================================================================
    wire clk_50m;
    wire pll_locked;
    wire sys_rst_n = rst_n & pll_locked;

    pll_clock u_pll (
        .inclk0 (clk_12m),
        .c0     (clk_50m),
        .locked (pll_locked)
    );

    // KEY4按下一次切换运行/暂停，上电后默认暂停。
    reg [1:0]  key4_sync;
    reg [15:0] key4_cnt;
    reg        key4_stable;
    reg        key4_stable_d;
    reg        run_enable;
    wire       key4_press = key4_stable_d & ~key4_stable;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            key4_sync     <= 2'b11;
            key4_cnt      <= 16'd0;
            key4_stable   <= 1'b1;
            key4_stable_d <= 1'b1;
            run_enable    <= 1'b0;
        end else begin
            key4_sync     <= {key4_sync[0], key4};
            key4_stable_d <= key4_stable;

            if (key4_sync[1] == key4_stable) begin
                key4_cnt <= 16'd0;
            end else if (key4_cnt == 16'd49999) begin
                key4_cnt    <= 16'd0;
                key4_stable <= key4_sync[1];
            end else begin
                key4_cnt <= key4_cnt + 1'b1;
            end

            if (key4_press)
                run_enable <= ~run_enable;
        end
    end

    // 系统运行秒计时，暂停时保持不变；二进制值用于EEPROM，BCD值用于LCD。
    localparam [25:0] SEC_TICK_MAX = 26'd49999999;
    reg [25:0] system_sec_cnt;
    reg [15:0] system_time_sec;
    reg [15:0] system_time_bcd;

    function [15:0] bcd_inc4;
        input [15:0] value;
        begin
            bcd_inc4 = value;
            if (value == 16'h9999) begin
                bcd_inc4 = 16'h0000;
            end else if (value[3:0] != 4'd9) begin
                bcd_inc4[3:0] = value[3:0] + 1'b1;
            end else if (value[7:4] != 4'd9) begin
                bcd_inc4[3:0] = 4'd0;
                bcd_inc4[7:4] = value[7:4] + 1'b1;
            end else if (value[11:8] != 4'd9) begin
                bcd_inc4[7:0]  = 8'h00;
                bcd_inc4[11:8] = value[11:8] + 1'b1;
            end else begin
                bcd_inc4[11:0]  = 12'h000;
                bcd_inc4[15:12] = value[15:12] + 1'b1;
            end
        end
    endfunction

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            system_sec_cnt  <= 26'd0;
            system_time_sec <= 16'd0;
            system_time_bcd <= 16'h0000;
        end else if (run_enable) begin
            if (system_sec_cnt == SEC_TICK_MAX) begin
                system_sec_cnt  <= 26'd0;
                system_time_sec <= system_time_sec + 1'b1;
                system_time_bcd <= bcd_inc4(system_time_bcd);
            end else begin
                system_sec_cnt <= system_sec_cnt + 1'b1;
            end
        end
    end

    //==========================================================================
    // 2. 采样触发（10kHz = 50MHz / 5000）
    //==========================================================================
    reg [12:0] sample_cnt;
    wire       sample_trig = run_enable && (sample_cnt == 13'd4999);

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            sample_cnt <= 13'd0;
        else if (run_enable) begin
            if (sample_cnt == 13'd4999)
                sample_cnt <= 13'd0;
            else
                sample_cnt <= sample_cnt + 1'b1;
        end
    end

    //==========================================================================
    // 3. 波形发生器（DDS + 故障注入）
    //==========================================================================
    wire [7:0] dac_data;
    wire       wave_valid;
    wire [2:0] active_fault_mode;

    waveform_gen u_wave (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .sample_trig (sample_trig),
        .fault_mode  (active_fault_mode),
        .amplitude   (8'd90),
        .wave_out    (dac_data),
        .wave_valid  (wave_valid)
    );

    //==========================================================================
    // 4. DAC 驱动
    //==========================================================================
    wire dac_busy;

    dac081s101_driver u_dac (
        .clk        (clk_50m),
        .rst_n      (sys_rst_n),
        .dac_trig   (sample_trig),
        .dac_data   (dac_data),
        .dac_busy   (dac_busy),
        .dac_sync_n (dac_sync_n),
        .dac_sclk   (dac_sclk),
        .dac_sdi    (dac_sdi)
    );

    //==========================================================================
    // 5. ADC 驱动
    //==========================================================================
    wire [7:0] adc_data;
    wire       adc_valid;
    wire       adc_sample_strobe = adc_valid;

    adc081s101_driver u_adc (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .sample_trig (sample_trig),
        .adc_data    (adc_data),
        .data_valid  (adc_valid),
        .adc_cs_n    (adc_cs_n),
        .adc_sclk    (adc_sclk),
        .adc_sdata   (adc_sdata)
    );

    //==========================================================================
    // 5a. ADC零点校准（KEY3触发，256点平均）
    //==========================================================================
    wire       key3_pulse;
    reg [15:0] key3_cnt;
    reg        key3_d, key3_d_prev;
    reg [7:0]  adc_center_cal;
    reg        adc_calib_active;
    reg [7:0]  adc_calib_count;
    reg [15:0] adc_calib_sum;
    wire [16:0] adc_calib_sum_next = {1'b0, adc_calib_sum} + {9'd0, adc_data};

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            key3_cnt <= 16'd0;
            key3_d   <= 1'b1;
        end else begin
            if (key3 == key3_d)
                key3_cnt <= 16'd0;
            else begin
                if (key3_cnt == 16'd49999) begin
                    key3_d   <= key3;
                    key3_cnt <= 16'd0;
                end else begin
                    key3_cnt <= key3_cnt + 1'b1;
                end
            end
        end
    end

    always @(posedge clk_50m)
        key3_d_prev <= key3_d;

    assign key3_pulse = key3_d_prev && !key3_d; // 下降沿表示按下

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            adc_center_cal    <= 8'd127;
            adc_calib_active  <= 1'b0;
            adc_calib_count   <= 8'd0;
            adc_calib_sum     <= 16'd0;
        end else begin
            if (key3_pulse && !adc_calib_active && active_fault_mode == 3'b000) begin
                adc_calib_active <= 1'b1;
                adc_calib_count  <= 8'd0;
                adc_calib_sum    <= 16'd0;
            end else if (adc_calib_active && active_fault_mode != 3'b000) begin
                adc_calib_active <= 1'b0;
                adc_calib_count  <= 8'd0;
                adc_calib_sum    <= 16'd0;
            end else if (adc_calib_active && adc_sample_strobe) begin
                adc_calib_sum   <= adc_calib_sum_next[15:0];
                adc_calib_count <= adc_calib_count + 1'b1;
                if (adc_calib_count == 8'hff) begin
                    adc_center_cal   <= adc_calib_sum_next[15:8];
                    adc_calib_active <= 1'b0;
                end
            end
        end
    end

    //==========================================================================
    // 6. 算法层：RMS + 频率 + 峰值
    //==========================================================================
    wire [7:0]  rms_val;
    wire        rms_valid;
    wire [15:0] period_cnt;
    wire        period_valid;
    wire [7:0]  peak_val;
    wire        peak_valid;

    rms_calculator u_rms (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .sample_trig (adc_sample_strobe),
        .adc_data    (adc_data),
        .adc_center  (adc_center_cal),
        .rms_value   (rms_val),
        .rms_valid   (rms_valid),
        .debug_mean  ()
    );

    freq_detector u_freq (
        .clk          (clk_50m),
        .rst_n        (sys_rst_n),
        .sample_trig  (adc_sample_strobe),
        .adc_data     (adc_data),
        .adc_center   (adc_center_cal),
        .period_cnt   (period_cnt),
        .period_valid (period_valid),
        .zero_cross   ()
    );

    peak_detector u_peak (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .sample_trig (adc_sample_strobe),
        .adc_data    (adc_data),
        .adc_center  (adc_center_cal),
        .peak_value  (peak_val),
        .peak_valid  (peak_valid)
    );

    // 仅降低人眼可见显示刷新率，减小读数跳动感。
    localparam [24:0] READOUT_UPDATE_INTERVAL = 25'd25000000; // 50MHz 下 500ms
    reg [24:0] readout_update_cnt;
    reg [7:0]  rms_display_val;
    reg [7:0]  peak_display_val;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            readout_update_cnt <= 25'd0;
            rms_display_val    <= 8'd0;
            peak_display_val   <= 8'd0;
        end else begin
            if (readout_update_cnt == READOUT_UPDATE_INTERVAL - 1'b1)
                readout_update_cnt <= 25'd0;
            else
                readout_update_cnt <= readout_update_cnt + 1'b1;

            if (readout_update_cnt == 25'd0) begin
                rms_display_val  <= rms_val;
                peak_display_val <= peak_val;
            end
        end
    end

    //==========================================================================
    // 7. 异常检测
    //==========================================================================
    wire [2:0] fault_type;
    wire       alarm_trig;
    wire       alarm_lvl;

    anomaly_detector u_anomaly (
        .clk          (clk_50m),
        .rst_n        (sys_rst_n),
        .sample_trig  (adc_sample_strobe),
        .rms_value    (rms_val),
        .rms_valid    (rms_valid),
        .period_cnt   (period_cnt),
        .period_valid (period_valid),
        .peak_value   (peak_val),
        .peak_valid   (peak_valid),
        .fault_mode   (active_fault_mode),
        .fault_type   (fault_type),
        .alarm_trigger(alarm_trig),
        .alarm_level  (alarm_lvl)
    );

    // 回放模式仍允许冻结生成的波形，但不作为新的故障事件写入。
    reg alarm_trig_d;
    reg alarm_for_record_d;
    wire alarm_freeze_pulse = alarm_trig & ~alarm_trig_d;
    wire alarm_for_record = alarm_trig & ~replay_active;
    wire real_alarm_pulse = alarm_for_record & ~alarm_for_record_d;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            alarm_trig_d       <= 1'b0;
            alarm_for_record_d <= 1'b0;
        end else begin
            alarm_trig_d       <= alarm_trig;
            alarm_for_record_d <= alarm_for_record;
        end
    end

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            last_fault_time_bcd   <= 16'h0000;
            last_fault_time_valid <= 1'b0;
            frozen_fault_time_bcd <= 16'h0000;
            frozen_fault_time_valid <= 1'b0;
            fault1_time_bcd <= 16'h0000;
            fault2_time_bcd <= 16'h0000;
            fault3_time_bcd <= 16'h0000;
            fault4_time_bcd <= 16'h0000;
            fault5_time_bcd <= 16'h0000;
            fault6_time_bcd <= 16'h0000;
            fault_time_valid_map <= 6'b000000;
            fault_record_active <= 1'b0;
            fault_start_sec <= 16'd0;
            last_fault_duration_sec <= 8'd0;
            duration_update_pulse <= 1'b0;
        end else if (real_alarm_pulse && fault_type != 3'b000) begin
            duration_update_pulse <= 1'b0;
            fault_record_active   <= 1'b1;
            fault_start_sec       <= system_time_sec;
            last_fault_duration_sec <= 8'd0;
            last_fault_time_bcd     <= system_time_bcd;
            last_fault_time_valid   <= 1'b1;
            frozen_fault_time_bcd   <= system_time_bcd;
            frozen_fault_time_valid <= 1'b1;
            case (fault_type)
                3'd1: begin
                    fault1_time_bcd <= system_time_bcd;
                    fault_time_valid_map[0] <= 1'b1;
                end
                3'd2: begin
                    fault2_time_bcd <= system_time_bcd;
                    fault_time_valid_map[1] <= 1'b1;
                end
                3'd3: begin
                    fault3_time_bcd <= system_time_bcd;
                    fault_time_valid_map[2] <= 1'b1;
                end
                3'd4: begin
                    fault4_time_bcd <= system_time_bcd;
                    fault_time_valid_map[3] <= 1'b1;
                end
                3'd5: begin
                    fault5_time_bcd <= system_time_bcd;
                    fault_time_valid_map[4] <= 1'b1;
                end
                3'd6: begin
                    fault6_time_bcd <= system_time_bcd;
                    fault_time_valid_map[5] <= 1'b1;
                end
                default: ;
            endcase
        end else begin
            duration_update_pulse <= 1'b0;
            if (fault_record_active) begin
                last_fault_duration_sec <= fault_elapsed_sec8;
                if (!alarm_lvl || fault_type == 3'b000 || replay_active) begin
                    fault_record_active <= 1'b0;
                    last_fault_duration_sec <= fault_elapsed_sec8;
                    duration_update_pulse <= 1'b1;
                end
            end
        end
    end

    //==========================================================================
    // 8. 波形冻结与缓存
    //==========================================================================
    wire       freeze_active;
    wire [9:0] trigger_addr;
    wire [9:0] ram_wr_addr;
    wire [7:0] ram_wr_data;
    wire       ram_we;
    wire [9:0] ram_rd_addr;
    wire [7:0] ram_rd_data;
    wire       lcd_read_next_sig;
    wire [4:0] record_count;
    wire       key2_pulse;
    wire       active_unfreeze;
    wire [2:0] frozen_fault_type;
    reg        replay_active;
    reg [2:0]  replay_fault_type;
    reg [15:0] replay_time_bcd;
    reg        replay_time_valid;
    reg [15:0] last_fault_time_bcd;
    reg        last_fault_time_valid;
    reg [15:0] frozen_fault_time_bcd;
    reg        frozen_fault_time_valid;
    reg [15:0] fault1_time_bcd;
    reg [15:0] fault2_time_bcd;
    reg [15:0] fault3_time_bcd;
    reg [15:0] fault4_time_bcd;
    reg [15:0] fault5_time_bcd;
    reg [15:0] fault6_time_bcd;
    reg [5:0]  fault_time_valid_map;
    reg        fault_record_active;
    reg [15:0] fault_start_sec;
    reg [7:0]  last_fault_duration_sec;
    reg        duration_update_pulse;
    wire [15:0] fault_elapsed_sec = system_time_sec - fault_start_sec;
    wire [7:0]  fault_elapsed_sec8 = (fault_elapsed_sec[15:8] != 8'd0) ? 8'd255 : fault_elapsed_sec[7:0];
    wire [7:0]  wifi_duration_sec = fault_record_active ? fault_elapsed_sec8 : last_fault_duration_sec;
    reg  [1:0] sw3_sync;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            sw3_sync <= 2'b00;
        else
            sw3_sync <= {sw3_sync[0], sw[3]};
    end

    wire lcd_ref_mode = sw3_sync[1];  // SW4：LCD显示内部DAC参考波形。
    // LCD绘图同样使用校准零点，将ADC数据重新映射到以128为中心。
    wire signed [9:0] adc_lcd_recentered =
        $signed({1'b0, adc_data}) - $signed({1'b0, adc_center_cal}) + 10'sd128;
    wire [7:0] adc_lcd_centered =
        adc_lcd_recentered < 10'sd0   ? 8'd0   :
        adc_lcd_recentered > 10'sd255 ? 8'd255 :
        adc_lcd_recentered[7:0];
    reg  [7:0] adc_lcd_d1;
    reg  [7:0] adc_lcd_d2;
    reg  [7:0] adc_lcd_filtered;
    wire [9:0] adc_lcd_filter_sum = {2'b00, adc_lcd_centered} +
                                     {1'b0, adc_lcd_d1, 1'b0} +
                                     {2'b00, adc_lcd_d2};

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            adc_lcd_d1       <= 8'd128;
            adc_lcd_d2       <= 8'd128;
            adc_lcd_filtered <= 8'd128;
        end else if (adc_sample_strobe) begin
            adc_lcd_filtered <= adc_lcd_filter_sum[9:2];
            adc_lcd_d2       <= adc_lcd_d1;
            adc_lcd_d1       <= adc_lcd_centered;
        end
    end

    wire [7:0] lcd_capture_data = lcd_ref_mode ? dac_data : adc_lcd_filtered;

    freeze_controller u_freeze (
        .clk           (clk_50m),
        .rst_n         (sys_rst_n),
        .sample_trig   (adc_sample_strobe),
        .adc_data      (lcd_capture_data),
        .alarm_trigger (alarm_freeze_pulse),
        .fault_type    (fault_type),
        .read_next     (lcd_read_next_sig),
        .unfreeze_trig (active_unfreeze),
        .wr_addr       (ram_wr_addr),
        .wr_data       (ram_wr_data),
        .wr_en         (ram_we),
        .rd_addr       (ram_rd_addr),
        .freeze_active (freeze_active),
        .trigger_addr  (trigger_addr),
        .fault_type_latch(frozen_fault_type)
    );

    wave_buffer u_buffer (
        .clk     (clk_50m),
        .wr_addr (ram_wr_addr),
        .wr_data (ram_wr_data),
        .wr_en   (ram_we),
        .rd_addr (ram_rd_addr),
        .rd_data (ram_rd_data)
    );

    //==========================================================================
    // 9. LCD 驱动（ST7789V SPI框架）
    //==========================================================================
    wire [2:0] lcd_fault_type = replay_active ? replay_fault_type :
                                (freeze_active ? frozen_fault_type : fault_type);
    wire [15:0] lcd_fault_time_bcd = replay_active ? replay_time_bcd :
                                     (freeze_active ? frozen_fault_time_bcd : last_fault_time_bcd);
    wire lcd_fault_time_valid = replay_active ? replay_time_valid :
                                (freeze_active ? frozen_fault_time_valid : last_fault_time_valid);
    wire lcd_time_is_fault = replay_active | freeze_active;
    wire [15:0] lcd_display_time_bcd = lcd_time_is_fault ?
                                       (lcd_fault_time_valid ? lcd_fault_time_bcd : 16'h0000) :
                                       system_time_bcd;

    lcd_driver u_lcd (
        .clk           (clk_50m),
        .rst_n         (sys_rst_n),
        .freeze_active (freeze_active),
        .wave_data     (ram_rd_data),
        .read_next     (lcd_read_next_sig),
        .fault_type    (lcd_fault_type),
        .rms_value     (rms_display_val),
        .peak_value    (peak_display_val),
        .freq_cnt      (period_cnt),
        .event_count   (record_count),
        .display_time_bcd(lcd_display_time_bcd),
        .display_time_is_fault(lcd_time_is_fault),
        .system_running(run_enable),
        .lcd_rst       (lcd_rst),
        .lcd_blk       (lcd_blk),
        .lcd_dc        (lcd_dc),
        .lcd_sclk      (lcd_sclk),
        .lcd_mosi      (lcd_mosi),
        .lcd_cs        (lcd_cs)
    );



    //==========================================================================
    // 10. 事件记录 + I2C主机（AT24C02）
    //==========================================================================
    wire        i2c_cmd_start;
    wire [7:0]  i2c_cmd_dev_addr;
    wire [7:0]  i2c_cmd_reg_addr;
    wire        i2c_cmd_has_reg;
    wire        i2c_cmd_rw;
    wire [7:0]  i2c_cmd_wdata;
    wire [7:0]  i2c_cmd_rdata;
    wire        i2c_cmd_ack_err;
    wire        i2c_cmd_done;
    wire        i2c_cmd_next;

    event_logger u_event (
        .clk          (clk_50m),
        .rst_n        (sys_rst_n),
        .alarm_trigger(real_alarm_pulse),
        .fault_type   (fault_type),
        .peak_value   (peak_val),
        .rms_value    (rms_val),
        .freq_value   (period_cnt[7:0]),
        .timestamp_sec(system_time_sec),
        .duration_update_trigger(duration_update_pulse),
        .duration_value(last_fault_duration_sec),
        .i2c_start    (i2c_cmd_start),
        .i2c_dev_addr (i2c_cmd_dev_addr),
        .i2c_reg_addr (i2c_cmd_reg_addr),
        .i2c_has_reg  (i2c_cmd_has_reg),
        .i2c_rw       (i2c_cmd_rw),
        .i2c_wdata    (i2c_cmd_wdata),
        .i2c_rdata    (i2c_cmd_rdata),
        .i2c_ack_err  (i2c_cmd_ack_err),
        .i2c_done     (i2c_cmd_done),
        .i2c_next     (i2c_cmd_next),
        .record_count (record_count),
        .log_busy     ()
    );

    i2c_master u_i2c (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .i2c_scl     (i2c_scl),
        .i2c_sda     (i2c_sda),
        .cmd_start   (i2c_cmd_start),
        .cmd_dev_addr(i2c_cmd_dev_addr),
        .cmd_reg_addr(i2c_cmd_reg_addr),
        .cmd_has_reg (i2c_cmd_has_reg),
        .cmd_rw      (i2c_cmd_rw),
        .cmd_wdata   (i2c_cmd_wdata),
        .cmd_rdata   (i2c_cmd_rdata),
        .cmd_ack_err (i2c_cmd_ack_err),
        .cmd_done    (i2c_cmd_done),
        .cmd_next    (i2c_cmd_next)
    );

    //==========================================================================
    // 11. 矩阵键盘与按键消抖
    //==========================================================================
    wire [3:0] key_code;
    wire       key_valid;
    wire       key_pressed;

    key_scan u_key (
        .clk         (clk_50m),
        .rst_n       (sys_rst_n),
        .row         (row),
        .col         (col),
        .key_code    (key_code),
        .key_valid   (key_valid),
        .key_pressed (key_pressed)
    );

    // KEY2消抖（低电平有效，1ms）
    reg [15:0] key2_cnt;
    reg        key2_d, key2_d_prev;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            key2_cnt <= 16'd0;
            key2_d   <= 1'b1;
        end else begin
            if (key2 == key2_d)
                key2_cnt <= 16'd0;
            else begin
                if (key2_cnt == 16'd49999) begin
                    key2_d   <= key2;
                    key2_cnt <= 16'd0;
                end else begin
                    key2_cnt <= key2_cnt + 1'b1;
                end
            end
        end
    end

    always @(posedge clk_50m)
        key2_d_prev <= key2_d;

    assign key2_pulse = key2_d_prev && !key2_d; // 下降沿表示按下
	 
//==========================================================================
// 拨码开关消抖（1ms @50MHz）
//==========================================================================
reg [2:0]  sw_sync, sw_stable;
reg [15:0] sw_cnt;

always @(posedge clk_50m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        sw_sync   <= 3'b000;
        sw_stable <= 3'b000;
        sw_cnt    <= 16'd0;
    end else begin
        sw_sync <= sw[2:0];  // 一级同步
        if (sw_sync == sw_stable) begin
            sw_cnt <= 16'd0;
        end else begin
            if (sw_cnt == 16'd50000) begin  // 1ms
                sw_stable <= sw_sync;
                sw_cnt    <= 16'd0;
            end else begin
                sw_cnt <= sw_cnt + 1'b1;
            end
        end
    end
end

    //==========================================================================
    // 12. 蜂鸣器
    //==========================================================================
    buzzer_driver u_buzz (
        .clk        (clk_50m),
        .rst_n      (sys_rst_n),
        .alarm_level(alarm_lvl),
        .fault_type (fault_type),
        .buzzer     (buzzer)
    );

    //==========================================================================
    // 13. 八位七段数码管显示（经74HC595驱动）
    //==========================================================================
    wire [31:0] disp_data;
    wire [15:0] seg_dig_data;
    wire        seg_load;
    wire        seg_busy;

    // 最高两位显示故障类型码“Fx”，冻结/回放时与LCD所示故障一致。
    // 其余六位继续显示RMS、周期计数和Peak，不改变原有数据读取逻辑。
    assign disp_data = {4'hF, 1'b0, lcd_fault_type,
                        rms_display_val, period_cnt[7:0], peak_display_val};

    seg_display_8bit u_seg8 (
        .clk      (clk_50m),
        .rst_n    (sys_rst_n),
        .disp_data(disp_data),
        .seg_dig  (seg_dig_data),
        .load     (seg_load),
        .busy     (seg_busy)
    );

    hc595_driver u_595 (
        .clk   (clk_50m),
        .rst_n (sys_rst_n),
        .data  (seg_dig_data),
        .load  (seg_load),
        .rck   (rck_595),
        .sclk   (sclk_595),
        .din   (din_595),
        .busy  (seg_busy)
    );

    //==========================================================================
    // 14. UART CH340（1Hz上传fault_type用于测试）
    //==========================================================================
    reg [25:0] uart_sec_cnt;
    reg [7:0]  uart_tx_data;
    reg        uart_tx_start;
    wire       uart_tx_busy;

    uart_tx u_uart_ch340 (
        .clk     (clk_50m),
        .rst_n   (sys_rst_n),
        .tx_data (uart_tx_data),
        .tx_start(uart_tx_start),
        .tx_busy (uart_tx_busy),
        .txd     (rxd_ch340)
    );

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            uart_sec_cnt  <= 26'd0;
            uart_tx_data  <= 8'd0;
            uart_tx_start <= 1'b0;
        end else begin
            uart_tx_start <= 1'b0;
            if (uart_sec_cnt == 26'd49999999) begin
                uart_sec_cnt <= 26'd0;
                uart_tx_data <= {5'b0, fault_type};
                if (!uart_tx_busy)
                    uart_tx_start <= 1'b1;
            end else begin
                uart_sec_cnt <= uart_sec_cnt + 1'b1;
            end
        end
    end

    //==========================================================================
    // 15. UART WiFi遥测（ESP8266 SoftAP TCP服务器，115200 8N1）
    //==========================================================================
    wire [7:0] wifi_freq_hz;
    assign wifi_freq_hz = (period_cnt == 16'd0)  ? 8'd0  :
                          (period_cnt <= 16'd198) ? 8'd51 :
                          (period_cnt >= 16'd202) ? 8'd49 :
                                                    8'd50;

    wifi_telemetry_tx u_wifi_telemetry (
        .clk           (clk_50m),
        .rst_n         (sys_rst_n),
        .rms_value     (rms_val),
        .peak_value    (peak_val),
        .freq_hz       (wifi_freq_hz),
        .fault_type    (fault_type),
        .fault_mode    (active_fault_mode),
        .freeze_active (freeze_active),
        .alarm_level   (alarm_lvl),
        .event_count   (record_count),
        .adc_data      (adc_data),
        .system_time_bcd(system_time_bcd),
        .duration_sec  (wifi_duration_sec),
        .system_running(run_enable),
        .txd           (rxd_wifi)
    );

    //==========================================================================
    // 15a. 状态输出
    //==========================================================================
    assign led      = {freeze_active, alarm_lvl, active_fault_mode, fault_type};
	 
    //==========================================================================
    // 15b. 矩阵键盘命令映射
    //   0   ：清除注入故障
    //   1~5 ：触发暂降、暂升、过频、欠频、削顶
    //   6   ：仅解除冻结
    //   7   ：触发谐波畸变
    //   8~D ：查看对应故障类型的最近一次记录时间
    //   E   ：将故障模式控制权交还给拨码开关SW[2:0]
    //   F   ：从1~6中伪随机触发一种故障
    //==========================================================================
    localparam [15:0] FAULT_REPLAY_DELAY = 16'd6000; // 10kHz下600ms，长于冻结解除锁定时间

    reg [2:0]  kb_fault_mode;
    reg [2:0]  pending_fault_mode;
    reg [15:0] fault_delay_cnt;
    reg        fault_delay_active;
    reg        kb_control_active;
    reg        kb_unfreeze;
    reg [7:0]  random_lfsr;

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            random_lfsr <= 8'hA5;
        else if (sample_trig)
            random_lfsr <= {random_lfsr[6:0],
                            random_lfsr[7] ^ random_lfsr[5] ^
                            random_lfsr[4] ^ random_lfsr[3]};
    end

    function key_is_fault_inject;
        input [3:0] code;
        begin
            case (code)
                4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd7, 4'd15:
                    key_is_fault_inject = 1'b1;
                default:
                    key_is_fault_inject = 1'b0;
            endcase
        end
    endfunction

    function key_is_replay_select;
        input [3:0] code;
        begin
            case (code)
                4'd8, 4'd9, 4'd10, 4'd11, 4'd12, 4'd13:
                    key_is_replay_select = 1'b1;
                default:
                    key_is_replay_select = 1'b0;
            endcase
        end
    endfunction

    function [2:0] key_to_fault_mode;
        input [3:0] code;
        input [7:0] random_state;
        reg [2:0] random_pick;
        begin
            random_pick = random_state[2:0] ^ random_state[5:3];
            case (code)
                4'd1, 4'd8:  key_to_fault_mode = 3'd1; // 暂降
                4'd2, 4'd9:  key_to_fault_mode = 3'd2; // 暂升
                4'd3, 4'd10: key_to_fault_mode = 3'd3; // 过频
                4'd4, 4'd11: key_to_fault_mode = 3'd4; // 欠频
                4'd5, 4'd12: key_to_fault_mode = 3'd5; // 削顶
                4'd7, 4'd13: key_to_fault_mode = 3'd6; // 谐波畸变
                4'd15: begin
                    case (random_pick)
                        3'd0: key_to_fault_mode = 3'd1;
                        3'd1: key_to_fault_mode = 3'd2;
                        3'd2: key_to_fault_mode = 3'd3;
                        3'd3: key_to_fault_mode = 3'd4;
                        3'd4: key_to_fault_mode = 3'd5;
                        3'd5: key_to_fault_mode = 3'd6;
                        3'd6: key_to_fault_mode = 3'd2;
                        default: key_to_fault_mode = 3'd5;
                    endcase
                end
                default:     key_to_fault_mode = 3'd0;
            endcase
        end
    endfunction

    always @(posedge clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            kb_fault_mode      <= 3'b000;
            pending_fault_mode <= 3'b000;
            fault_delay_cnt    <= 16'd0;
            fault_delay_active <= 1'b0;
            kb_control_active  <= 1'b0;
            kb_unfreeze        <= 1'b0;
            replay_active      <= 1'b0;
            replay_fault_type  <= 3'b000;
            replay_time_bcd    <= 16'h0000;
            replay_time_valid  <= 1'b0;
        end else begin
            kb_unfreeze <= 1'b0;

            if (fault_delay_active && sample_trig) begin
                if (fault_delay_cnt == 16'd0) begin
                    fault_delay_active <= 1'b0;
                    kb_fault_mode      <= pending_fault_mode;
                    pending_fault_mode <= 3'b000;
                end else begin
                    fault_delay_cnt <= fault_delay_cnt - 1'b1;
                end
            end

            if (key_valid) begin
                if (key_is_fault_inject(key_code)) begin
                    replay_active <= 1'b0;
                    kb_control_active <= 1'b1;
                    pending_fault_mode <= key_to_fault_mode(key_code, random_lfsr);

                    if (freeze_active || active_fault_mode != 3'b000) begin
                        kb_fault_mode      <= 3'b000;
                        fault_delay_active <= 1'b1;
                        fault_delay_cnt    <= FAULT_REPLAY_DELAY;
                        kb_unfreeze        <= freeze_active;
                    end else begin
                        fault_delay_active <= 1'b0;
                        kb_fault_mode      <= key_to_fault_mode(key_code, random_lfsr);
                    end
                end else if (key_is_replay_select(key_code)) begin
                    kb_control_active  <= 1'b1;
                    pending_fault_mode <= key_to_fault_mode(key_code, random_lfsr);
                    replay_active      <= 1'b1;
                    replay_fault_type  <= key_to_fault_mode(key_code, random_lfsr);
                    case (key_to_fault_mode(key_code, random_lfsr))
                        3'd1: begin
                            replay_time_bcd   <= fault1_time_bcd;
                            replay_time_valid <= fault_time_valid_map[0];
                        end
                        3'd2: begin
                            replay_time_bcd   <= fault2_time_bcd;
                            replay_time_valid <= fault_time_valid_map[1];
                        end
                        3'd3: begin
                            replay_time_bcd   <= fault3_time_bcd;
                            replay_time_valid <= fault_time_valid_map[2];
                        end
                        3'd4: begin
                            replay_time_bcd   <= fault4_time_bcd;
                            replay_time_valid <= fault_time_valid_map[3];
                        end
                        3'd5: begin
                            replay_time_bcd   <= fault5_time_bcd;
                            replay_time_valid <= fault_time_valid_map[4];
                        end
                        3'd6: begin
                            replay_time_bcd   <= fault6_time_bcd;
                            replay_time_valid <= fault_time_valid_map[5];
                        end
                        default: begin
                            replay_time_bcd   <= 16'h0000;
                            replay_time_valid <= 1'b0;
                        end
                    endcase

                    if (freeze_active || active_fault_mode != 3'b000) begin
                        kb_fault_mode      <= 3'b000;
                        fault_delay_active <= 1'b1;
                        fault_delay_cnt    <= FAULT_REPLAY_DELAY;
                        kb_unfreeze        <= freeze_active;
                    end else begin
                        fault_delay_active <= 1'b0;
                        kb_fault_mode      <= key_to_fault_mode(key_code, random_lfsr);
                    end
                end else begin
                    case (key_code)
                        4'd0: begin
                            kb_control_active  <= 1'b1;
                            kb_fault_mode      <= 3'b000;
                            pending_fault_mode <= 3'b000;
                            fault_delay_active <= 1'b0;
                            replay_active      <= 1'b0;
                        end
                        4'd6: begin
                            // 仅解除波形冻结，故障模式继续保持；键0负责清除故障。
                            kb_unfreeze <= 1'b1;
                        end
                        4'd14: begin
                            kb_control_active  <= 1'b0;
                            kb_fault_mode      <= 3'b000;
                            pending_fault_mode <= 3'b000;
                            fault_delay_active <= 1'b0;
                            replay_active      <= 1'b0;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

// 键盘一旦接管，按键 0 可以强制正常；按键 E 交还给拨码开关。
wire [2:0] sw_fault_mode = (sw_stable <= 3'd6) ? sw_stable : 3'd0;
assign active_fault_mode = kb_control_active ? kb_fault_mode : sw_fault_mode;
assign active_unfreeze   = key2_pulse | kb_unfreeze;

    //==========================================================================
    // 16. 保留输入
    //==========================================================================
    // txd_ch340、txd_wifi目前仅保留为对应串口模块的接收输入。
    // 未使用逻辑会在综合时自然优化。
	 

endmodule
