`timescale 1ns/1ps
`default_nettype none

// E1 mechanism experiment. Policies are intentionally implemented in the test
// harness, not in the RTL or a real Linux service. The RAM allocation stays live.
module tb_dma_buffer_reuse;
    parameter integer ROWS = 64, COLS = 64;
    localparam integer FRAME_WORDS = (ROWS+1)*COLS/4;
    localparam integer RAM_WORDS = 2*ROWS+16, FIRST_WORD = 8;
    localparam logic [31:0] RAM_BASE = 32'h1000, BUFFER_BASE = RAM_BASE+FIRST_WORD*4;
    localparam logic [31:0] JOB_A = 32'ha001, JOB_B = 32'hb002;
    localparam logic [31:0] B_PATTERN = 32'ha5a5a5a5;
    localparam integer WATCH_LIMIT = 4*ROWS*COLS + 40*ROWS + 10000;
    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;
    `include "axil_signals.svh"
    `include "axi_write_signals.svh"
    logic [31:0] s_axis_tdata = 0;
    logic [3:0] s_axis_tkeep = 4'hf;
    logic s_axis_tvalid = 0, s_axis_tlast = 0;
    wire s_axis_tready;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    wire m_axis_tvalid, m_axis_tready, m_axis_tlast, irq;
    logic arm_valid = 0;
    wire arm_ready;
    logic [31:0] arm_address = 0, arm_words = 0, arm_job_id = 0;
    logic [31:0] arm_generation = 0, arm_write_delay = 0;
    wire dma_active, dma_done, dma_fault;
    wire [2:0] dma_error;
    wire [31:0] dma_job_id, dma_generation, stream_beats, written_beats;
    logic commit_enable = 0;
    logic [31:0] response_delay = 0;
    wire ram_idle, ram_pending, commit_valid, commit_success;
    wire [31:0] commit_address, commit_data;
    wire [3:0] commit_strobes;
    integer channel_tick = 0;
    wire allow_aw = (channel_tick % 4) != 0;
    wire allow_w = (channel_tick % 7) != 2 && (channel_tick % 7) != 3;
    wire allow_bready = (channel_tick % 5) != 0;
    // Readiness changes only at falling edges, avoiding a sampling race.
    always @(negedge aclk)
        if (!aresetn) channel_tick <= 0; else channel_tick <= channel_tick+1;

    kv260_matvec #(.ROWS(ROWS), .COLS(COLS)) dut (.*);
    axil_master_bfm bus (.*);
    s2mm_write_model dma (
        .s_axis_tdata(m_axis_tdata), .s_axis_tkeep(m_axis_tkeep),
        .s_axis_tvalid(m_axis_tvalid), .s_axis_tlast(m_axis_tlast),
        .s_axis_tready(m_axis_tready), .active(dma_active), .done(dma_done),
        .fault(dma_fault), .error_code(dma_error), .job_id(dma_job_id),
        .generation(dma_generation), .*
    );
    axi_write_ram_model #(.BASE_ADDRESS(RAM_BASE), .WORDS(RAM_WORDS)) ram (
        .idle(ram_idle), .pending_write(ram_pending), .*
    );
    axi_write_checker protocol_check (.*);

    integer cycle_count = 0, current_policy = -1, current_trial = -1;
    integer timeout_cycle, reuse_cycle, first_reuse_cycle, dma_done_cycle, core_irq_cycle;
    integer first_a_commit, cross_writes, cross_bytes, stream_seen;
    integer seed = 20261029, trials = 3, active_seed;
    integer trace_fd, metrics_fd, index, policy, trial, latency_hold;
    integer bad_response, old_completion_rejected, returned_a_bytes;
    integer changed_bytes, normal_followup_ok, core_before_dma;
    logic [31:0] owner = 0, rng = 0, value, client_response [0:ROWS-1];
    logic measuring = 0, phase_a = 0;
    string metrics_path, trace_path;

    function automatic [31:0] guard_value(input integer word_index);
        return 32'hc0ffee00 ^ 32'(word_index);
    endfunction
    function automatic [31:0] expected_word(input logic job_b, input integer row);
        integer result;
        result = job_b ? 2*COLS*(3+row%5) : -3*COLS*(1+row%64);
        return 32'(result);
    endfunction
    function automatic [31:0] frame_word(input logic job_b, input integer word_index);
        logic [31:0] result;
        integer lane, byte_index, row, element;
        result = 0;
        for (lane = 0; lane < 4; lane = lane+1) begin
            byte_index = 4*word_index+lane;
            if (byte_index < COLS) element = job_b ? 2 : -3;
            else begin
                row = (byte_index-COLS)/COLS;
                element = job_b ? 3+row%5 : 1+row%64;
            end
            result[8*lane +: 8] = element[7:0];
        end
        return result;
    endfunction
    task automatic trace_event(input string event_name, input logic [31:0] address,
                                input logic [31:0] data);
        $fwrite(trace_fd, "%0d,%0d,%0d,%s,%0h,%0h,%0h,%0h\n",
                current_trial, current_policy, cycle_count, event_name,
                dma_job_id, owner, address, data);
    endtask

    always @(posedge aclk) begin
        cycle_count = cycle_count+1;
        if (aresetn && measuring) begin
            if (dma_fault) $fatal(1, "DMA model fault %0d", dma_error);
            if (phase_a && irq && core_irq_cycle < 0) begin
                core_irq_cycle = cycle_count;
                trace_event("core_irq", 0, 0);
            end
            if (m_axis_tvalid && m_axis_tready) begin
                if (stream_seen >= ROWS || m_axis_tdata !== expected_word(!phase_a, stream_seen) ||
                    m_axis_tkeep !== 4'hf || m_axis_tlast !== (stream_seen == ROWS-1))
                    $fatal(1, "Core-to-DMA payload mismatch row %0d", stream_seen);
                stream_seen = stream_seen+1;
                trace_event("stream_accept", 0, m_axis_tdata);
            end
            if (m_axi_awvalid && m_axi_awready) trace_event("aw_accept", m_axi_awaddr, 0);
            if (m_axi_wvalid && m_axi_wready) trace_event("w_accept", 0, m_axi_wdata);
            if (commit_valid && !commit_success) $fatal(1, "Unexpected RAM write error");
            if (commit_success) begin
                if (commit_address < BUFFER_BASE || commit_address >= BUFFER_BASE+32'(ROWS*4))
                    $fatal(1, "DMA escaped the designated output buffer");
                if (phase_a && first_a_commit < 0) first_a_commit = cycle_count;
                if (dma_job_id != owner) begin
                    cross_writes = cross_writes+1;
                    for (integer lane = 0; lane < 4; lane = lane+1)
                        if (commit_strobes[lane]) cross_bytes = cross_bytes+1;
                end
                trace_event("memory_commit", commit_address, commit_data);
            end
            if (m_axi_bvalid && m_axi_bready) trace_event("b_accept", 0, {30'd0, m_axi_bresp});
        end
    end

    task automatic reset_all();
        @(negedge aclk);
        aresetn = 0; bus.idle(); arm_valid = 0;
        s_axis_tvalid = 0; s_axis_tlast = 0; measuring = 0; commit_enable = 0;
        repeat (3) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        @(posedge aclk); #2;
        if (!arm_ready || dma_active || dma_fault || !ram_idle || irq)
            $fatal(1, "Experiment did not reset to idle");
    endtask
    task automatic arm_dma(input logic job_b, input integer write_delay);
        @(negedge aclk);
        arm_address = BUFFER_BASE; arm_words = 32'(ROWS);
        arm_job_id = job_b ? JOB_B : JOB_A;
        arm_generation = job_b ? 2 : 1; arm_write_delay = 32'(write_delay); arm_valid = 1;
        if (!arm_ready) $fatal(1, "Attempted to reprogram an active descriptor");
        @(posedge aclk); #2;
        trace_event("descriptor_arm", BUFFER_BASE, 32'(ROWS));
        @(negedge aclk); arm_valid = 0;
        // These changing, unaccepted pins must not retarget the active transfer.
        arm_address = 32'hffff0000; arm_words = 0;
        arm_job_id = 0; arm_generation = 0; arm_write_delay = 32'hffffffff;
    endtask
    task automatic start_core(input logic job_b, input integer delay_cycles);
        bus.write_reg(12'h010, job_b ? JOB_B : JOB_A, 4'hf, 0, 0, 0);
        bus.write_reg(12'h014, job_b ? 2 : 1, 4'hf, 1, 0, 0);
        bus.write_reg(12'h018, 32'(delay_cycles), 4'hf, -1, 0, 0);
        bus.write_reg(12'h008, 1, 4'h1, 0, 0, 0);
        trace_event("core_start", 0, 0);
    endtask
    task automatic send_frame(input logic job_b);
        integer word_index, waits, gap;
        for (word_index = 0; word_index < FRAME_WORDS; word_index = word_index+1) begin
            rng = rng*32'd1664525+32'd1013904223;
            gap = integer'(rng[3:0]) % 3;
            repeat (gap) @(negedge aclk);
            @(negedge aclk);
            s_axis_tdata = frame_word(job_b, word_index); s_axis_tkeep = 4'hf;
            s_axis_tlast = word_index == FRAME_WORDS-1; s_axis_tvalid = 1;
            waits = 0; @(posedge aclk);
            while (!s_axis_tready) begin
                waits = waits+1;
                if (waits > 100) $fatal(1, "Experiment input timed out");
                @(posedge aclk);
            end
            @(negedge aclk); s_axis_tvalid = 0; s_axis_tlast = 0;
        end
    endtask
    task automatic wait_dma();
        integer waits;
        waits = 0;
        while (!dma_done) begin
            @(posedge aclk); #2;
            waits = waits+1;
            if (dma_fault || waits > WATCH_LIMIT) $fatal(1, "DMA did not complete");
        end
        if (dma_active || !ram_idle || written_beats != ROWS || stream_beats != ROWS)
            $fatal(1, "DMA done did not include all memory responses");
    endtask
    task automatic check_guards();
        for (integer word_index = 0; word_index < RAM_WORDS; word_index = word_index+1)
            if ((word_index < FIRST_WORD || word_index >= FIRST_WORD+ROWS) &&
                ram.cpu_read(word_index) !== guard_value(word_index))
                $fatal(1, "Neighbor/guard changed at word %0d", word_index);
    endtask
    task automatic give_buffer_to_b();
        @(negedge aclk); owner = JOB_B; reuse_cycle = cycle_count;
        for (integer row = 0; row < ROWS; row = row+1)
            ram.cpu_write(FIRST_WORD+row, B_PATTERN);
        trace_event("owner_b", BUFFER_BASE, B_PATTERN);
    endtask

    task automatic run_policy(input integer selected_policy, selected_trial);
        integer waits, selected_delay, byte_index;
        logic [31:0] actual;
        reset_all();
        current_policy = selected_policy; current_trial = selected_trial;
        active_seed = seed + selected_trial;
        rng = 32'(active_seed);
        selected_delay = (selected_trial % 3 == 0) ? 0 : ((selected_trial % 3 == 1) ? 3 : 17);
        response_delay = 32'((selected_trial % 3)*5);
        timeout_cycle = -1; reuse_cycle = -1; dma_done_cycle = -1;
        core_irq_cycle = -1; first_a_commit = -1; cross_writes = 0; cross_bytes = 0;
        stream_seen = 0; bad_response = 0; old_completion_rejected = 0;
        returned_a_bytes = 0; changed_bytes = 0; normal_followup_ok = 0;
        owner = JOB_A; phase_a = 1;
        @(negedge aclk);
        for (integer word_index = 0; word_index < RAM_WORDS; word_index = word_index+1)
            ram.cpu_write(word_index, guard_value(word_index));
        for (integer row = 0; row < ROWS; row = row+1)
            ram.cpu_write(FIRST_WORD+row, 32'h11111111);
        measuring = 1;
        trace_event("owner_a", BUFFER_BASE, 0);
        bus.write_reg(12'h01c, 3, 4'h1, 0, 0, 0);
        arm_dma(0, selected_delay);
        start_core(0, selected_trial % 3 * 7);
        send_frame(0);
        waits = 0;
        while (!ram_pending) begin
            @(posedge aclk); #2;
            waits = waits+1;
            if (waits > WATCH_LIMIT) $fatal(1, "No accepted write to delay");
        end
        // Both AXI channels have accepted A; memory commit is deliberately held.
        repeat (12 + selected_trial%3*12) begin @(posedge aclk); #2; end
        timeout_cycle = cycle_count;
        if (!dma_active || written_beats != 0 || !ram_pending)
            $fatal(1, "Timeout was not inside A's outstanding write window");
        trace_event("host_timeout", BUFFER_BASE, 0);
        if (selected_policy < 2) give_buffer_to_b();
        else @(negedge aclk); // Same fault-release schedule for all policies.
        @(negedge aclk); commit_enable = 1;
        wait_dma();
        dma_done_cycle = cycle_count;
        trace_event("dma_done_a", BUFFER_BASE, written_beats);
        core_before_dma = core_irq_cycle >= 0 && core_irq_cycle < dma_done_cycle;
        if (!core_before_dma) $fatal(1, "Expected core completion before DMA completion");
        bus.read_reg(12'h00c, 0, 0, value);
        if (value[2:0] !== 3'b010) $fatal(1, "Core is not quiescent after A drain");
        bus.expect_reg(12'h070, JOB_A);
        bus.expect_reg(12'h074, 1);
        bus.expect_reg(12'h094, 1);
        if (dma_job_id != JOB_A || dma_generation != 1)
            $fatal(1, "Descriptor identity changed before completion");
        for (integer row = 0; row < ROWS; row = row+1) begin
            actual = ram.cpu_read(FIRST_WORD+row);
            if (actual !== expected_word(0, row)) $fatal(1, "A write missing from RAM");
            if (selected_policy < 2)
                for (byte_index = 0; byte_index < 4; byte_index = byte_index+1)
                    if (actual[8*byte_index +: 8] !== B_PATTERN[8*byte_index +: 8])
                        changed_bytes = changed_bytes+1;
        end
        check_guards();

        // Deliberately minimal service-completion model, not a production driver.
        // P0 associates A's completion with the current owner B and returns RAM.
        // P1 checks descriptor ID/generation and rejects that same completion.
        if (selected_policy == 0) begin
            for (integer row = 0; row < ROWS; row = row+1) begin
                client_response[row] = ram.cpu_read(FIRST_WORD+row);
                if (client_response[row] !== expected_word(1, row)) bad_response = 1;
                if (client_response[row] === expected_word(0, row)) returned_a_bytes += 4;
            end
            trace_event("mock_b_response_bad", BUFFER_BASE, 32'(returned_a_bytes));
        end else begin
            if (dma_job_id == JOB_B && dma_generation == 2)
                $fatal(1, "Old A descriptor unexpectedly matches B");
            old_completion_rejected = 1;
            trace_event("old_completion_rejected", BUFFER_BASE, 0);
        end
        if (selected_policy == 2) begin
            if (cross_writes != 0 || dma_active || !ram_idle)
                $fatal(1, "P2 released before quiescence");
            give_buffer_to_b();
        end
        first_reuse_cycle = reuse_cycle;
        latency_hold = first_reuse_cycle-timeout_cycle;
        if (selected_policy < 2 && (cross_writes != ROWS || cross_bytes != ROWS*4))
            $fatal(1, "Positive control did not reproduce every late write");
        if (selected_policy == 2 && (cross_writes != 0 || reuse_cycle < dma_done_cycle))
            $fatal(1, "P2 isolation/reuse contract failed");
        // P1/P2 now service B. For P0, this is a separate recovery probe after
        // the bad mock B response; it must not be interpreted as repairing it.
        phase_a = 0; stream_seen = 0;
        @(negedge aclk);
        if (owner != JOB_B) $fatal(1, "Follow-up does not own the buffer");
        for (integer row = 0; row < ROWS; row = row+1)
            ram.cpu_write(FIRST_WORD+row, B_PATTERN);
        trace_event("cpu_init_b_followup", BUFFER_BASE, B_PATTERN);
        repeat (12) begin @(posedge aclk); #2; end
        for (integer row = 0; row < ROWS; row = row+1)
            if (ram.cpu_read(FIRST_WORD+row) !== B_PATTERN)
                $fatal(1, "Old write arrived after the drain fence");
        bus.write_reg(12'h020, 1, 4'h1, 0, 0, 0);
        arm_dma(1, 0);
        start_core(1, 0);
        send_frame(1);
        wait_dma();
        for (integer row = 0; row < ROWS; row = row+1)
            if (ram.cpu_read(FIRST_WORD+row) !== expected_word(1, row))
                $fatal(1, "Normal follow-up job B is incorrect");
        if (cross_writes != ((selected_policy < 2) ? ROWS : 0))
            $fatal(1, "Follow-up job introduced an ownership violation");
        check_guards(); normal_followup_ok = 1;
        $fwrite(metrics_fd,
            {"{\"rows\":%0d,\"cols\":%0d,\"seed\":%0d,\"trial\":%0d,\"policy\":\"P%0d\",",
             "\"write_delay\":%0d,\"response_delay\":%0d,\"timeout_cycle\":%0d,",
             "\"reuse_cycle\":%0d,\"dma_done_cycle\":%0d,\"core_irq_cycle\":%0d,",
             "\"first_a_commit_cycle\":%0d,\"cross_owner_writes\":%0d,\"cross_owner_bytes\":%0d,",
             "\"changed_b_bytes\":%0d,\"mock_bad_b_response\":%0d,\"a_payload_bytes_returned_to_b\":%0d,",
             "\"old_completion_rejected\":%0d,\"quarantine_cycles\":%0d,",
             "\"core_done_before_dma_done\":%0d,\"normal_followup_ok\":%0d,\"guard_violations\":0}\n"},
            ROWS, COLS, active_seed, selected_trial, selected_policy, selected_delay, response_delay,
            timeout_cycle, first_reuse_cycle,
            dma_done_cycle, core_irq_cycle, first_a_commit, cross_writes, cross_bytes, changed_bytes,
            bad_response, returned_a_bytes, old_completion_rejected, (selected_policy == 2) ? latency_hold : 0,
            core_before_dma, normal_followup_ok);
        $display("REUSE P%0d trial=%0d writes_into_B=%0d bad_mock_response=%0d hold=%0d cycles",
                 selected_policy, selected_trial, cross_writes, bad_response,
                 (selected_policy == 2) ? latency_hold : 0);
        measuring = 0;
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("TRIALS=%d", trials)) begin end
        if (trials < 1) $fatal(1, "TRIALS must be positive");
        metrics_path = $sformatf("build/reuse_%0dx%0d.jsonl", ROWS, COLS);
        trace_path = $sformatf("build/reuse_%0dx%0d.trace.csv", ROWS, COLS);
        metrics_fd = $fopen(metrics_path, "w"); trace_fd = $fopen(trace_path, "w");
        if (!metrics_fd || !trace_fd) $fatal(1, "Cannot create experiment logs");
        $fwrite(trace_fd, "trial,policy,cycle,event,dma_job,owner,address,data\n");
        for (trial = 0; trial < trials; trial = trial+1)
            for (policy = 0; policy < 3; policy = policy+1) run_policy(policy, trial);
        $fclose(metrics_fd); $fclose(trace_fd);
        $display("PASS buffer-reuse rows=%0d cols=%0d cases=%0d", ROWS, COLS, trials*3);
        $finish;
    end
    initial begin #1000000000; $fatal(1, "Buffer-reuse experiment watchdog"); end
endmodule

`default_nettype wire
