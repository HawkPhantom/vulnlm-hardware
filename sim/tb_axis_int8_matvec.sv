`timescale 1ns/1ps
`default_nettype none

module tb_axis_int8_matvec;
    parameter integer ROWS = 64;
    parameter integer COLS = 64;
    localparam integer FRAME_WORDS = (ROWS + 1) * COLS / 4;
    localparam integer WAIT_LIMIT = 4 * ROWS * COLS + 2000;

    logic aclk = 0;
    always #5 aclk = ~aclk;
    logic aresetn = 0;
    logic start_valid = 0;
    wire start_ready;
    logic [31:0] cfg_job_id = 0, cfg_generation = 0, cfg_delay_cycles = 0;
    logic [31:0] s_axis_tdata = 0;
    logic [3:0] s_axis_tkeep = 4'hf;
    logic s_axis_tvalid = 0, s_axis_tlast = 0;
    wire s_axis_tready;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    wire m_axis_tvalid, m_axis_tlast;
    logic m_axis_tready = 0;
    wire busy, done, fault;
    wire [2:0] error_code;
    wire [31:0] active_job_id, active_generation, input_beats, output_beats;
    wire [63:0] elapsed_cycles, output_stall_cycles;

    axis_int8_matvec #(.ROWS(ROWS), .COLS(COLS)) dut (.*);

    integer x_ref [0:COLS-1];
    integer w_ref [0:ROWS*COLS-1];
    logic signed [31:0] expected [0:ROWS-1];
    logic [31:0] rng = 32'h1947cafe;
    integer seed = 20261029;
    integer random_jobs = 20;
    integer checks = 0, jobs = 0, received = 0;
    integer first_valid_cycle = -1, last_input_cycle = -1;
    integer cycle_count = 0, start_cycle = 0;
    integer golden_stalls = 0;
    logic model_enabled = 0;
    logic [31:0] expected_job_id, expected_generation;
    logic was_stalled = 0;
    logic [31:0] held_data;
    logic [3:0] held_keep;
    logic held_last;
    logic last_output_fire;

    function automatic logic [31:0] random_word();
        rng = rng * 32'd1664525 + 32'd1013904223;
        return rng;
    endfunction

    // Independent integer reference, accumulated wider than the DUT.
    task automatic prepare_data(input integer kind);
        integer r, c, value;
        logic [31:0] random_value;
        logic signed [63:0] total;
        for (c = 0; c < COLS; c = c + 1) begin
            random_value = random_word();
            case (kind)
                0: value = 0;
                1: value = (c * 13 + 17) % 256 - 128;
                2: value = 127;
                3: value = -128;
                4: value = (c % 2) ? 127 : -128;
                6: value = -128;
                default: value = integer'(random_value[31:24]) - 128;
            endcase
            x_ref[c] = value;
        end
        for (r = 0; r < ROWS; r = r + 1) begin
            total = 0;
            for (c = 0; c < COLS; c = c + 1) begin
                random_value = random_word();
                case (kind)
                    0: value = integer'(random_value[31:24]) - 128;
                    1: value = (c == r % COLS) ? 1 : 0;
                    2: value = 127;
                    3: value = -128;
                    4: value = ((r + c) % 2) ? -128 : 127;
                    6: value = 127;
                    default: value = integer'(random_value[31:24]) - 128;
                endcase
                w_ref[r*COLS+c] = value;
                total = total + 64'(x_ref[c]) * 64'(value);
            end
            expected[r] = total[31:0];
        end
    endtask

    function automatic logic [31:0] frame_word(input integer index);
        logic [31:0] word_value;
        integer lane, byte_index, value;
        word_value = 0;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            byte_index = 4 * index + lane;
            if (byte_index < COLS)
                value = x_ref[byte_index];
            else
                value = w_ref[byte_index-COLS];
            word_value[lane*8 +: 8] = value[7:0];
        end
        return word_value;
    endfunction

    // Samples transfers before DUT nonblocking assignments, then checks DONE.
    always @(posedge aclk) begin
        cycle_count = cycle_count + 1;
        if (!aresetn) begin
            was_stalled = 0;
        end else begin
            if (was_stalled &&
                (!m_axis_tvalid || m_axis_tdata !== held_data ||
                 m_axis_tkeep !== held_keep || m_axis_tlast !== held_last))
                $fatal(1, "AXI output changed while stalled at cycle %0d", cycle_count);
            if (start_valid && start_ready) begin
                start_cycle = cycle_count;
                golden_stalls = 0;
            end
            if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
                last_input_cycle = cycle_count;
            if (m_axis_tvalid && first_valid_cycle < 0)
                first_valid_cycle = cycle_count;
            if (m_axis_tvalid && !m_axis_tready)
                golden_stalls = golden_stalls + 1;
            if (m_axis_tvalid && (!model_enabled || fault))
                $fatal(1, "Unexpected output without a valid complete job");
            if (model_enabled && busy &&
                (active_job_id !== expected_job_id ||
                 active_generation !== expected_generation))
                $fatal(1, "Configuration changed during an active job");
            last_output_fire = m_axis_tvalid && m_axis_tready && m_axis_tlast;
            if (m_axis_tvalid && m_axis_tready) begin
                if (received >= ROWS)
                    $fatal(1, "Duplicate output beat");
                if (m_axis_tdata !== expected[received])
                    $fatal(1, "Row %0d got %0d expected %0d", received,
                           $signed(m_axis_tdata), $signed(expected[received]));
                if (m_axis_tkeep !== 4'hf || m_axis_tlast !== (received == ROWS-1))
                    $fatal(1, "Invalid output KEEP/LAST at row %0d", received);
                received = received + 1;
            end
            was_stalled = m_axis_tvalid && !m_axis_tready;
            held_data = m_axis_tdata;
            held_keep = m_axis_tkeep;
            held_last = m_axis_tlast;
            #1;
            if (done !== last_output_fire)
                $fatal(1, "DONE does not match final output handshake");
        end
    end

    task automatic reset_datapath();
        @(negedge aclk);
        aresetn = 0;
        start_valid = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 0;
        model_enabled = 0;
        repeat (3) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1;
        @(posedge aclk); #2;
        if (!start_ready || busy || fault || done || m_axis_tvalid ||
            input_beats != 0 || output_beats != 0 || elapsed_cycles != 0 ||
            output_stall_cycles != 0 || error_code != 0)
            $fatal(1, "Reset did not return a clean control state");
        checks = checks + 1;
    endtask

    task automatic begin_job(input integer delay_cycles, input logic check_output);
        @(negedge aclk);
        jobs = jobs + 1;
        expected_job_id = 32'habc00000 + 32'(jobs);
        expected_generation = 32'(jobs + 17);
        cfg_job_id = expected_job_id;
        cfg_generation = expected_generation;
        cfg_delay_cycles = 32'(delay_cycles);
        received = 0;
        first_valid_cycle = -1;
        last_input_cycle = -1;
        model_enabled = check_output;
        start_valid = 1;
        if (!start_ready) $fatal(1, "Job did not start from IDLE");
        @(posedge aclk); #2;
        if (!busy || start_ready || !s_axis_tready)
            $fatal(1, "Job start was not accepted");
        @(negedge aclk);
        start_valid = 0;
        // Changing the pins must not change an already latched job.
        cfg_job_id = 32'hdeadbeef;
        cfg_generation = 32'hbadcafe;
        cfg_delay_cycles = 32'hffff_ffff;
    endtask

    task automatic send_word(input logic [31:0] data_value,
                             input logic [3:0] keep_value,
                             input logic last_value);
        integer waits;
        @(negedge aclk);
        s_axis_tdata = data_value;
        s_axis_tkeep = keep_value;
        s_axis_tlast = last_value;
        s_axis_tvalid = 1;
        waits = 0;
        @(posedge aclk);
        while (!s_axis_tready) begin
            waits = waits + 1;
            if (waits > 20) $fatal(1, "Input handshake timed out");
            @(posedge aclk);
        end
        @(negedge aclk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
    endtask

    task automatic send_frame();
        integer index, gap;
        logic [31:0] random_value;
        for (index = 0; index < FRAME_WORDS; index = index + 1) begin
            random_value = random_word();
            gap = integer'(random_value[2:0]) % 3;
            repeat (gap) @(negedge aclk);
            // A second start while busy must never replace the active job.
            if (index == 1) start_valid = 1;
            send_word(frame_word(index), 4'hf, index == FRAME_WORDS-1);
            start_valid = 0;
        end
    endtask

    task automatic finish_job(input logic stall_outputs,
                              output integer latency);
        integer waits;
        logic final_stall_tested;
        logic [31:0] random_value;
        waits = 0;
        while (!m_axis_tvalid) begin
            @(posedge aclk); #2;
            waits = waits + 1;
            if (fault || waits > WAIT_LIMIT)
                $fatal(1, "No first result");
        end
        if (stall_outputs) repeat (5) begin @(posedge aclk); #2; end
        final_stall_tested = 0;
        waits = 0;
        while (!done) begin
            @(negedge aclk);
            if (stall_outputs && m_axis_tvalid && m_axis_tlast && !final_stall_tested) begin
                m_axis_tready = 0;
                repeat (7) begin @(posedge aclk); #2; end
                final_stall_tested = 1;
            end else begin
                random_value = random_word();
                m_axis_tready = !stall_outputs || (random_value[3:0] < 11);
                @(posedge aclk); #2;
            end
            waits = waits + 1;
            if (fault || waits > WAIT_LIMIT) $fatal(1, "Output drain timed out");
        end
        latency = first_valid_cycle - last_input_cycle;
        if (received != ROWS || input_beats != FRAME_WORDS || output_beats != ROWS)
            $fatal(1, "Transfer count mismatch");
        if (output_stall_cycles != 64'(golden_stalls))
            $fatal(1, "Stall counter mismatch: got %0d expected %0d",
                   output_stall_cycles, golden_stalls);
        if (elapsed_cycles != 64'(cycle_count - start_cycle))
            $fatal(1, "Elapsed counter mismatch");
        if (!start_ready || busy || error_code != 0)
            $fatal(1, "Normal completion did not return to IDLE");
        @(negedge aclk);
        m_axis_tready = 0;
        model_enabled = 0;
        repeat (4) begin
            @(posedge aclk); #2;
            if (done || m_axis_tvalid) $fatal(1, "Duplicate completion/output");
        end
        checks = checks + 1;
    endtask

    task automatic run_case(input integer kind, input integer delay_cycles,
                            input logic stall_outputs, output integer latency);
        prepare_data(kind);
        begin_job(delay_cycles, 1);
        send_frame();
        finish_job(stall_outputs, latency);
    endtask

    task automatic check_bad_frame(input integer kind);
        integer index;
        logic [2:0] expected_error;
        prepare_data(5);
        begin_job(0, 0);
        case (kind)
            1: begin
                send_word(frame_word(0), 4'h7, 0);
                expected_error = 1;
            end
            2: begin
                send_word(frame_word(0), 4'hf, 1);
                expected_error = 2;
            end
            default: begin
                for (index = 0; index < FRAME_WORDS; index = index + 1)
                    send_word(frame_word(index), 4'hf, 0);
                expected_error = 3;
            end
        endcase
        @(posedge aclk); #2;
        if (!fault || error_code != expected_error || input_beats == 0)
            $fatal(1, "Malformed frame was not rejected: kind %0d", kind);
        @(negedge aclk);
        start_valid = 1;
        s_axis_tvalid = 1;
        s_axis_tlast = 1;
        repeat (8) begin
            @(posedge aclk); #2;
            if (!fault || start_ready || s_axis_tready || m_axis_tvalid || done)
                $fatal(1, "FAULTED accepted traffic or emitted output");
        end
        reset_datapath();
        checks = checks + 1;
    endtask

    task automatic check_reset_in_phase(input integer phase);
        integer index, latency, waits;
        prepare_data(5);
        begin_job((phase == 2) ? 500 : 0, 1);
        if (phase == 0) begin
            send_word(frame_word(0), 4'hf, 0);
        end else begin
            send_frame();
            case (phase)
                1: repeat (3) begin @(posedge aclk); #2; end
                2: repeat (2*COLS + 8) begin @(posedge aclk); #2; end
                default: begin
                    waits = 0;
                    while (!m_axis_tvalid) begin
                        @(posedge aclk); #2;
                        waits = waits + 1;
                        if (waits > WAIT_LIMIT) $fatal(1, "Reset setup timed out");
                    end
                    if (phase == 4 && ROWS > 1) begin
                        @(negedge aclk); m_axis_tready = 1;
                        @(posedge aclk); #2;
                        @(negedge aclk); m_axis_tready = 0;
                        waits = 0;
                        while (!m_axis_tvalid) begin
                            @(posedge aclk); #2;
                            waits = waits + 1;
                            if (waits > WAIT_LIMIT) $fatal(1, "Second row timed out");
                        end
                    end
                    repeat (4) begin @(posedge aclk); #2; end
                end
            endcase
        end
        reset_datapath();
        // Reload completely different data without clearing the RAM arrays.
        run_case(1, 0, 1, latency);
        checks = checks + 1;
    endtask

    integer index, latency, baseline_latency, delayed_latency;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("JOBS=%d", random_jobs)) begin end
        rng = 32'(seed);
        if ($test$plusargs("VCD")) begin
            $dumpfile("build/matvec.vcd");
            $dumpvars(0, tb_axis_int8_matvec);
        end
        reset_datapath();
        // Idle input is not consumed without a start command.
        @(negedge aclk); s_axis_tvalid = 1; s_axis_tlast = 1;
        repeat (4) begin
            @(posedge aclk); #2;
            if (s_axis_tready || m_axis_tvalid || input_beats != 0)
                $fatal(1, "Unsolicited input was consumed in IDLE");
        end
        @(negedge aclk); s_axis_tvalid = 0; s_axis_tlast = 0;

        for (index = 0; index <= 6; index = index + 1)
            run_case(index, 0, 1, latency);
        run_case(1, 0, 0, baseline_latency);
        run_case(1, 17, 1, delayed_latency);
        if (delayed_latency - baseline_latency != 17)
            $fatal(1, "Injected delay was not exactly 17 cycles: base=%0d delayed=%0d",
                   baseline_latency, delayed_latency);
        run_case(1, 1, 0, latency);
        if (latency - baseline_latency != 1) $fatal(1, "One-cycle delay off by one");

        // A host-only timeout is an observation, not a hardware cancellation.
        prepare_data(5);
        begin_job(100, 1);
        send_frame();
        repeat (20) begin @(posedge aclk); #2; end
        if (!busy || done || m_axis_tvalid)
            $fatal(1, "Host timeout setup did not leave a pending job");
        $display("HOST_TIMEOUT: job=%0h remains active; waiting for late output", active_job_id);
        finish_job(1, latency);

        for (index = 0; index < random_jobs; index = index + 1)
            run_case(5, (index % 4) * 7, 1, latency);
        for (index = 1; index <= 3; index = index + 1) begin
            check_bad_frame(index);
            run_case(5, 0, 1, latency);
        end
        for (index = 0; index < 5; index = index + 1)
            check_reset_in_phase(index);
        $display("PASS rows=%0d cols=%0d seed=%0d jobs=%0d checks=%0d cycles=%0d",
                 ROWS, COLS, seed, jobs, checks, cycle_count);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "Global simulation watchdog expired");
    end
endmodule

`default_nettype wire
