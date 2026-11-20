module servo_pwm #(
    parameter CLOCKS_PER_US = 84
)(
    input wire clk,
    input wire reset,
    input wire write_pulse,
    input wire [31:0] pulse_us,
    output wire signal
);
    reg [$clog2(CLOCKS_PER_US)-1:0] divider;
    reg [14:0] frame_us;
    reg [10:0] pending_us;
    reg [10:0] active_us;

    assign signal = !reset && frame_us < active_us;

    always @(posedge clk) begin
        if (reset) begin
            divider <= 0;
            frame_us <= 0;
            pending_us <= 0;
            active_us <= 0;
        end else begin
            if (write_pulse && (pulse_us == 0 || (pulse_us >= 1000 && pulse_us <= 2000)))
                pending_us <= pulse_us[10:0];

            if (divider == CLOCKS_PER_US-1) begin
                divider <= 0;
                if (frame_us == 19999) begin
                    frame_us <= 0;
                    active_us <= pending_us;
                end else begin
                    frame_us <= frame_us + 1'b1;
                end
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end
endmodule
