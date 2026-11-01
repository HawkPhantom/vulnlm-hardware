`timescale 1ns/1ps
`default_nettype none
module tb_dma_models;
    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;
    `include "axi_write_signals.svh"
    logic arm_valid = 0;
    wire arm_ready;
    logic [31:0] arm_address = 0, arm_words = 0, arm_job_id = 0, arm_generation = 0;
    logic [31:0] arm_write_delay = 0, s_axis_tdata = 0;
    logic [3:0] s_axis_tkeep = 4'hf;
    logic s_axis_tvalid = 0, s_axis_tlast = 0;
    wire s_axis_tready, active, done, fault;
    wire [2:0] error_code;
    wire [31:0] job_id, generation, stream_beats, written_beats;
    logic allow_aw = 1, allow_w = 1, allow_bready = 1, commit_enable = 1;
    logic [31:0] response_delay = 4;
    wire idle, pending_write, commit_valid, commit_success;
    wire [31:0] commit_address, commit_data;
    wire [3:0] commit_strobes;
    integer aw_count = 0, w_count = 0, commits = 0, checks = 0;
    s2mm_write_model dut (.*);
    axi_write_ram_model #(.WORDS(16)) ram (.*);
    axi_write_checker protocol_check (.*);

    always @(posedge aclk) begin
        if (!aresetn) begin aw_count = 0; w_count = 0; commits = 0; end
        else begin
            if (m_axi_awvalid && m_axi_awready) aw_count += 1;
            if (m_axi_wvalid && m_axi_wready) w_count += 1;
            if (commit_success) commits += 1;
        end
    end
    task automatic reset_all();
        @(negedge aclk);
        aresetn = 0; arm_valid = 0; s_axis_tvalid = 0; s_axis_tlast = 0;
        allow_aw = 1; allow_w = 1; allow_bready = 1; commit_enable = 1;
        repeat (3) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        @(posedge aclk); #2;
        if (!arm_ready || active || done || fault || !idle)
            $fatal(1, "DMA models did not reset");
    endtask
    task automatic arm(input logic [31:0] address, count, delay_cycles);
        @(negedge aclk);
        arm_address = address; arm_words = count; arm_write_delay = delay_cycles;
        arm_job_id = 32'h1234; arm_generation = 9; arm_valid = 1;
        if (!arm_ready) $fatal(1, "Test arm while not ready");
        @(posedge aclk); #2;
        @(negedge aclk); arm_valid = 0;
        arm_address = 32'hdead0000; arm_words = 0; arm_write_delay = 32'hffffffff;
        arm_job_id = 0; arm_generation = 0;
    endtask
    task automatic beat(input logic [31:0] value, input logic [3:0] keep, input logic last);
        integer waits;
        @(negedge aclk);
        s_axis_tdata = value; s_axis_tkeep = keep; s_axis_tlast = last; s_axis_tvalid = 1;
        waits = 0; @(posedge aclk);
        while (!s_axis_tready) begin
            waits += 1;
            if (waits > 100) $fatal(1, "Model input timed out");
            @(posedge aclk);
        end
        @(negedge aclk); s_axis_tvalid = 0;
    endtask
    task automatic wait_done();
        integer waits;
        waits = 0;
        while (!done) begin
            @(posedge aclk); #2;
            waits += 1;
            if (fault || waits > 100) $fatal(1, "Model done timed out");
        end
        if (active || !idle) $fatal(1, "Done before B completion");
        checks += 1;
    endtask
    task automatic expect_fault(input logic [2:0] code, input logic no_axi);
        integer waits;
        waits = 0;
        while (!fault) begin
            @(posedge aclk); #2;
            waits += 1;
            if (waits > 100) $fatal(1, "Expected DMA model fault missing");
        end
        if (error_code !== code || done || arm_ready || s_axis_tready || commits != 0)
            $fatal(1, "Fault contract failed");
        if (no_axi && (aw_count != 0 || w_count != 0))
            $fatal(1, "Invalid descriptor/frame reached memory AXI");
        repeat (5) begin
            @(posedge aclk); #2;
            if (!fault || done) $fatal(1, "Fault not sticky");
        end
        checks += 1;
    endtask

    integer waits;
    initial begin
        reset_all();
        @(negedge aclk);
        for (integer index = 0; index < 16; index += 1) ram.cpu_write(index, 32'hcafef00d);
        allow_aw = 0; allow_bready = 0; commit_enable = 0;
        arm(32'h1000, 2, 3);
        beat(32'h11223344, 4'hf, 0);
        waits = 0;
        while (w_count == 0) begin
            @(posedge aclk); #2;
            waits += 1;
            if (waits > 30) $fatal(1, "W improperly waited for AWREADY");
        end
        if (aw_count != 0 || done || commits != 0) $fatal(1, "W-first setup failed");
        // A short re-arm attempt must be ignored while busy, not retargeted.
        @(negedge aclk); arm_valid = 1;
        @(posedge aclk); #2;
        if (arm_ready || job_id != 32'h1234 || generation != 9)
            $fatal(1, "Active descriptor was retargeted");
        @(negedge aclk); arm_valid = 0; allow_aw = 1;
        waits = 0;
        while (!pending_write) begin
            @(posedge aclk); #2;
            waits += 1;
            if (waits > 30) $fatal(1, "AW did not join the pending W");
        end
        repeat (8) begin @(posedge aclk); #2; end
        if (ram.cpu_read(0) !== 32'hcafef00d || written_beats != 0 || done)
            $fatal(1, "Accepted write committed before commit gate");
        @(negedge aclk); commit_enable = 1;
        waits = 0;
        while (!m_axi_bvalid) begin
            @(posedge aclk); #2;
            waits += 1;
            if (waits > 30) $fatal(1, "No write response");
        end
        repeat (12) begin @(posedge aclk); #2; end
        if (ram.cpu_read(0) !== 32'h11223344 || written_beats != 0 || done || !active)
            $fatal(1, "Memory commit was confused with B acceptance");
        @(negedge aclk); allow_bready = 1;
        beat(32'h55667788, 4'hf, 1);
        wait_done();
        if (stream_beats != 2 || written_beats != 2 || commits != 2 ||
            ram.cpu_read(1) !== 32'h55667788) $fatal(1, "Two-word transfer mismatch");
        reset_all();
        if (ram.cpu_read(0) !== 32'h11223344) $fatal(1, "Reset unexpectedly erased model RAM");

        @(negedge aclk); allow_w = 0;
        arm(32'h1008, 1, 0);
        beat(32'h87654321, 4'hf, 1);
        waits = 0;
        while (aw_count == 0) begin
            @(posedge aclk); #2;
            waits += 1;
            if (waits > 30) $fatal(1, "AW improperly waited for WREADY");
        end
        if (w_count != 0) $fatal(1, "AW-first setup failed");
        @(negedge aclk); allow_w = 1;
        wait_done();
        if (ram.cpu_read(2) !== 32'h87654321) $fatal(1, "AW-first data mismatch");

        reset_all(); arm(32'h1000, 0, 0); expect_fault(1, 1);
        reset_all(); arm(32'h1001, 1, 0); expect_fault(1, 1);
        reset_all(); arm(32'hfffffffc, 2, 0); expect_fault(1, 1);
        reset_all(); arm(32'h1000, 1, 0); beat(7, 4'h7, 1); expect_fault(2, 1);
        reset_all(); arm(32'h1000, 2, 0); beat(7, 4'hf, 1); expect_fault(2, 1);
        reset_all(); arm(32'h1000, 1, 0); beat(7, 4'hf, 0); expect_fault(2, 1);
        // Aligned descriptor outside model RAM must return SLVERR, not alias.
        reset_all(); arm(32'h1040, 1, 0); beat(32'hdeadbeef, 4'hf, 1); expect_fault(3, 0);
        if (ram.cpu_read(0) !== 32'h11223344 || ram.cpu_read(2) !== 32'h87654321)
            $fatal(1, "Out-of-range write changed unrelated RAM");
        $display("PASS dma-models checks=%0d", checks);
        $finish;
    end
    initial begin #1000000; $fatal(1, "DMA model unit watchdog"); end
endmodule
`default_nettype wire
