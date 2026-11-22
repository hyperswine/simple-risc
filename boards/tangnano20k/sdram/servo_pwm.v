// Pin 76 on the SDRAM_SERVO image, written at 0x10001010. Software decides
// what the pin does; the hardware only holds what it was told:
//   1000-2000  servo PWM: that many microseconds high in each 20 ms frame,
//              from the next frame boundary
//   1          level high at once (a transistor or other on/off load; the
//              program times it), and PWM off from the next frame
//   0          level low at once, and PWM off from the next frame (a pulse
//              in progress finishes, so a servo never sees a runt)
// Any other value is ignored. Reset drives the pin low.
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
    reg level;

    assign signal = !reset && (level || frame_us < active_us);

    always @(posedge clk) begin
        if (reset) begin
            divider <= 0;
            frame_us <= 0;
            pending_us <= 0;
            active_us <= 0;
            level <= 0;
        end else begin
            if (write_pulse && pulse_us == 1) begin
                level <= 1;
                pending_us <= 0;
            end else if (write_pulse && (pulse_us == 0 || (pulse_us >= 1000 && pulse_us <= 2000))) begin
                level <= 0;
                pending_us <= pulse_us[10:0];
            end

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
