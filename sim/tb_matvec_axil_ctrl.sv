`timescale 1ns/1ps
`default_nettype none

module tb_matvec_axil_ctrl;
    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;
    `include "axil_signals.svh"
    wire core_start_valid, irq;
    wire abort_drain, recovery_release;
    wire receive_hold;
    logic recovery_active=0,recovery_drained=0;
    logic [31:0] recovery_count=0,stream_state=0,stream_output_beats=0;
    wire [31:0] cfg_job_id, cfg_generation, cfg_delay_cycles;
    logic core_start_ready = 1, core_busy = 0, core_done = 0, core_fault = 0;
    logic [2:0] core_error_code = 0;
    logic [31:0] core_job_id = 0, core_generation = 0;
    logic [31:0] core_input_beats = 0, core_output_beats = 0;
    logic [63:0] core_elapsed_cycles = 0, core_output_stall_cycles = 0;
    matvec_axil_ctrl dut (.*);
    axil_master_bfm bus (.*);
    integer starts = 0, index;
    logic [31:0] value, model_value, random_value;
    logic [31:0] rng = 32'h701ca11;
    logic [3:0] strobes;
    integer lane;

    always @(posedge aclk)
        if (aresetn && core_start_valid && core_start_ready) starts = starts + 1;

    task automatic reset_all();
        @(negedge aclk); aresetn = 0; bus.idle();
        core_start_ready = 1; core_busy = 0; core_done = 0; core_fault = 0;
        core_error_code = 0; core_job_id = 0; core_generation = 0;
        core_input_beats = 0; core_output_beats = 0;
        core_elapsed_cycles = 0; core_output_stall_cycles = 0;
        repeat (3) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        @(posedge aclk); #2;
        if (s_axi_bvalid || s_axi_rvalid || irq || core_start_valid)
            $fatal(1, "Reset left a response/event pending");
    endtask

    task automatic pulse_done();
        @(negedge aclk); core_done = 1;
        @(posedge aclk); #2;
        @(negedge aclk); core_done = 0;
    endtask

    initial begin
        reset_all();
        bus.expect_reg(12'h000, 32'h4d565831);
        bus.expect_reg(12'h004, 32'h00010001);
        bus.expect_reg(12'h00c, 2);
        bus.expect_reg(12'h030, 64);
        bus.expect_reg(12'h034, 64);
        bus.expect_reg(12'h038, 4160);
        bus.expect_reg(12'h03c, 256);
        // AW first, W first, same-cycle, and delayed B/R acceptance.
        bus.write_reg(12'h010, 32'h11223344, 4'hf, 1, 7, 0);
        bus.write_reg(12'h010, 32'haabbccdd, 4'h5, -1, 5, 0);
        bus.expect_reg(12'h010, 32'h11bb33dd);
        bus.write_reg(12'h010, 32'hffffffff, 4'h0, 0, 3, 0);
        bus.expect_reg(12'h010, 32'h11bb33dd);
        model_value = 32'h11bb33dd;
        for (index = 0; index < 32; index = index + 1) begin
            rng = rng * 32'd1664525 + 32'd1013904223;
            random_value = rng;
            strobes = rng[19:16];
            for (lane = 0; lane < 4; lane = lane + 1)
                if (strobes[lane]) model_value[8*lane +: 8] = random_value[8*lane +: 8];
            // Read and write channels may proceed independently.
            fork
                bus.write_reg(12'h010, random_value, strobes, (index % 3)-1, index % 5, 0);
                bus.expect_reg(12'h000, 32'h4d565831);
            join
            bus.expect_reg(12'h010, model_value);
        end

        bus.write_reg(12'h000, 32'h12345678, 4'hf, 0, 2, 2);
        bus.expect_reg(12'h000, 32'h4d565831);
        bus.write_reg(12'h011, 32'hffffffff, 4'hf, 1, 2, 2);
        bus.expect_reg(12'h010, model_value);
        bus.write_reg(12'h110, 32'hffffffff, 4'hf, -1, 2, 2);
        bus.expect_reg(12'h010, model_value);
        bus.read_reg(12'h011, 5, 2, value);
        if (value !== 0) $fatal(1, "Unaligned read leaked data");
        bus.read_reg(12'h110, 3, 2, value);
        if (value !== 0) $fatal(1, "Undefined address aliased a register");
        bus.write_reg(12'h008, 3, 4'hf, 0, 0, 2);
        bus.write_reg(12'h008, 1, 4'h0, 0, 0, 0);
        if (starts != 0) $fatal(1, "Reserved/zero-strobe command started a job");
        bus.write_reg(12'h008, 1, 4'h1, -1, 3, 0);
        if (starts != 1) $fatal(1, "START did not produce exactly one handshake");
        @(negedge aclk); core_busy = 1; core_start_ready = 0;
        core_job_id = model_value; core_generation = 9;
        bus.write_reg(12'h008, 1, 4'hf, 1, 4, 2);
        if (starts != 1) $fatal(1, "Busy START was queued or accepted");
        bus.write_reg(12'h010, 32'h76543210, 4'hf, 0, 0, 0);
        bus.expect_reg(12'h010, 32'h76543210);
        bus.expect_reg(12'h028, model_value);

        // An accepted read must retain its value while the live register changes.
        bus.send_ar(12'h028);
        core_job_id = 32'hdeadcafe;
        bus.take_r(7, 0, value);
        if (value !== model_value) $fatal(1, "Live register changed a pending read response");
        core_job_id = model_value;

        // A snapshot must survive a simulated 64-bit counter rollover.
        @(negedge aclk);
        core_elapsed_cycles = 64'h00000000ffffffff;
        core_output_stall_cycles = 64'h12345678abcdef01;
        core_input_beats = 100; core_output_beats = 7;
        bus.write_reg(12'h040, 1, 4'h1, 0, 8, 0);
        @(negedge aclk); core_elapsed_cycles = 64'h0000000100000000;
        core_output_stall_cycles = 64'hffffffff00000000;
        bus.expect_reg(12'h044, 1);
        bus.expect_reg(12'h048, model_value);
        bus.expect_reg(12'h04c, 9);
        bus.expect_reg(12'h050, 100);
        bus.expect_reg(12'h054, 7);
        bus.expect_reg(12'h058, 32'hffffffff);
        bus.expect_reg(12'h05c, 0);
        bus.expect_reg(12'h060, 32'habcdef01);
        bus.expect_reg(12'h064, 32'h12345678);
        bus.write_reg(12'h040, 1, 4'h0, 0, 0, 0);
        bus.write_reg(12'h040, 3, 4'h1, 0, 0, 2);
        bus.expect_reg(12'h044, 1);
        bus.write_reg(12'h040, 1, 4'h1, -1, 0, 0);
        bus.expect_reg(12'h044, 2);
        bus.expect_reg(12'h058, 0);
        bus.expect_reg(12'h05c, 1);

        @(negedge aclk);
        core_busy = 0; core_start_ready = 1;
        core_elapsed_cycles = 64'hfedcba9876543210;
        core_output_stall_cycles = 64'h1122334455667788;
        pulse_done();
        bus.expect_reg(12'h020, 1);
        if (irq) $fatal(1, "Masked IRQ asserted");
        bus.write_reg(12'h01c, 1, 4'h1, 0, 0, 0);
        if (!irq) $fatal(1, "Unmasking a pending event lost the interrupt");
        bus.expect_reg(12'h06c, 1);
        bus.expect_reg(12'h070, model_value);
        bus.expect_reg(12'h074, 9);
        bus.expect_reg(12'h078, 0);
        bus.expect_reg(12'h07c, 100);
        bus.expect_reg(12'h080, 7);
        bus.expect_reg(12'h084, 32'h76543210);
        bus.expect_reg(12'h088, 32'hfedcba98);
        bus.expect_reg(12'h08c, 32'h55667788);
        bus.expect_reg(12'h090, 32'h11223344);
        bus.expect_reg(12'h094, 1);
        bus.write_reg(12'h020, 1, 4'h0, 0, 0, 0);
        if (!irq) $fatal(1, "Zero-strobe W1C cleared IRQ");

        // An event on the W1C commit edge must win over the clear.
        fork bus.send_aw(12'h020); bus.send_w(1, 4'h1); join
        core_done = 1;
        @(posedge aclk); #2;
        @(negedge aclk); core_done = 0;
        bus.take_b(3, 0);
        bus.expect_reg(12'h020, 1);
        bus.expect_reg(12'h06c, 2);
        bus.write_reg(12'h020, 1, 4'h1, 0, 0, 0);
        if (irq) $fatal(1, "W1C failed to clear done IRQ");

        bus.write_reg(12'h01c, 3, 4'h1, 0, 0, 0);
        @(negedge aclk); core_fault = 1; core_busy = 1; core_start_ready = 0;
        core_error_code = 2;
        repeat (4) begin @(posedge aclk); #2; end
        bus.expect_reg(12'h020, 2);
        bus.expect_reg(12'h024, 2);
        bus.expect_reg(12'h06c, 3);
        bus.expect_reg(12'h078, 2);
        bus.expect_reg(12'h094, 2);
        if (!irq) $fatal(1, "Fault interrupt missing");
        bus.write_reg(12'h020, 2, 4'h1, 0, 0, 0);
        repeat (8) begin @(posedge aclk); #2; end
        if (irq) $fatal(1, "Persistent FAULT retriggered instead of edge-latching");
        bus.expect_reg(12'h06c, 3);
        bus.write_reg(12'h008, 1, 4'h1, 0, 0, 2);

        // Reset a split write, a pending B response, and a pending R response.
        reset_all();
        bus.send_aw(12'h010);
        reset_all();
        bus.write_reg(12'h018, 17, 4'hf, -1, 0, 0);
        bus.expect_reg(12'h010, 0);
        bus.expect_reg(12'h018, 17);
        reset_all();
        bus.send_w(32'hbadf00d, 4'hf);
        reset_all();
        bus.write_reg(12'h014, 77, 4'hf, 1, 0, 0);
        bus.expect_reg(12'h018, 0);
        bus.expect_reg(12'h014, 77);
        fork bus.send_aw(12'h014); bus.send_w(99, 4'hf); join
        repeat (3) begin @(posedge aclk); #2; end
        if (!s_axi_bvalid) $fatal(1, "No pending B for reset test");
        reset_all();
        bus.send_ar(12'h000);
        if (!s_axi_rvalid) $fatal(1, "No pending R for reset test");
        reset_all();
        bus.expect_reg(12'h014, 0);
        bus.expect_reg(12'h020, 0);
        bus.expect_reg(12'h044, 0);
        bus.expect_reg(12'h06c, 0);
        bus.expect_reg(12'h00c, 2);
        $display("PASS axil-control writes=%0d reads=%0d starts=%0d", bus.writes, bus.reads, starts);
        $finish;
    end

    initial begin #1000000; $fatal(1, "AXI-Lite unit watchdog"); end
endmodule

`default_nettype wire
