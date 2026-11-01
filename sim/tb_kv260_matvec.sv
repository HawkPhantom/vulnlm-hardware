`timescale 1ns/1ps
`default_nettype none

module tb_kv260_matvec;
    parameter integer ROWS = 64, COLS = 64;
    localparam integer FRAME_WORDS = (ROWS + 1) * COLS / 4;
    localparam integer WAIT_LIMIT = 4 * ROWS * COLS + 2000;
    logic aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;
    `include "axil_signals.svh"
    logic [31:0] s_axis_tdata = 0;
    logic [3:0] s_axis_tkeep = 4'hf;
    logic s_axis_tvalid = 0, s_axis_tlast = 0;
    wire s_axis_tready;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    wire m_axis_tvalid, m_axis_tlast, irq;
    logic m_axis_tready = 0;
    kv260_matvec #(.ROWS(ROWS), .COLS(COLS)) dut (.*);
    axil_master_bfm bus (.*);

    integer x_ref [0:COLS-1], w_ref [0:ROWS*COLS-1];
    logic [31:0] expected [0:ROWS-1];
    logic [31:0] rng = 32'h20261029;
    integer seed = 20261029, received = 0, cycle_count = 0, golden_stalls = 0;
    integer first_valid_cycle = -1, last_input_cycle = -1;
    logic model_enabled = 0, was_stalled = 0;
    logic [31:0] held_data;
    logic held_last;

    function automatic logic [31:0] random_word();
        rng = rng * 32'd1664525 + 32'd1013904223;
        return rng;
    endfunction

    task automatic prepare_data();
        integer row, col;
        logic [31:0] random_value;
        logic signed [63:0] sum;
        for (col = 0; col < COLS; col = col + 1) begin
            random_value = random_word();
            x_ref[col] = integer'(random_value[31:24]) - 128;
        end
        for (row = 0; row < ROWS; row = row + 1) begin
            sum = 0;
            for (col = 0; col < COLS; col = col + 1) begin
                random_value = random_word();
                w_ref[row*COLS+col] = integer'(random_value[31:24]) - 128;
                sum = sum + 64'(x_ref[col]) * 64'(w_ref[row*COLS+col]);
            end
            expected[row] = sum[31:0];
        end
        @(negedge aclk);
        received = 0; golden_stalls = 0;
        first_valid_cycle = -1; last_input_cycle = -1; model_enabled = 1;
    endtask

    function automatic logic [31:0] frame_word(input integer index);
        logic [31:0] result;
        integer lane, byte_index, value;
        result = 0;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            byte_index = 4*index + lane;
            value = (byte_index < COLS) ? x_ref[byte_index] : w_ref[byte_index-COLS];
            result[8*lane +: 8] = value[7:0];
        end
        return result;
    endfunction

    always @(posedge aclk) begin
        cycle_count = cycle_count + 1;
        if (!aresetn) begin
            was_stalled = 0;
        end else begin
            if (was_stalled && (!m_axis_tvalid || m_axis_tdata !== held_data ||
                                m_axis_tlast !== held_last || m_axis_tkeep !== 4'hf))
                $fatal(1, "Integrated stream changed under backpressure");
            if (m_axis_tvalid && !model_enabled)
                $fatal(1, "Output without an expected job");
            if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
                last_input_cycle = cycle_count;
            if (m_axis_tvalid && first_valid_cycle < 0) first_valid_cycle = cycle_count;
            if (m_axis_tvalid && !m_axis_tready) golden_stalls = golden_stalls + 1;
            if (m_axis_tvalid && m_axis_tready) begin
                if (received >= ROWS) $fatal(1, "Too many output rows");
                if (m_axis_tdata !== expected[received] || m_axis_tkeep !== 4'hf ||
                    m_axis_tlast !== (received == ROWS-1))
                    $fatal(1, "Integrated output mismatch at row %0d", received);
                received = received + 1;
            end
            was_stalled = m_axis_tvalid && !m_axis_tready;
            held_data = m_axis_tdata; held_last = m_axis_tlast;
        end
    end

    task automatic reset_all();
        @(negedge aclk);
        aresetn = 0; bus.idle(); model_enabled = 0;
        s_axis_tvalid = 0; s_axis_tlast = 0; m_axis_tready = 0;
        repeat (3) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        @(posedge aclk); #2;
        if (irq || m_axis_tvalid || s_axi_bvalid || s_axi_rvalid)
            $fatal(1, "Peripheral reset left stale traffic");
        bus.expect_reg(12'h00c, 2);
        bus.expect_reg(12'h06c, 0);
    endtask

    task automatic send_word(input logic [31:0] value, input logic last_value);
        integer waits;
        @(negedge aclk);
        s_axis_tdata = value; s_axis_tkeep = 4'hf;
        s_axis_tlast = last_value; s_axis_tvalid = 1;
        waits = 0;
        @(posedge aclk);
        while (!s_axis_tready) begin
            waits = waits + 1;
            if (waits > 100) $fatal(1, "Integrated stream input timed out");
            @(posedge aclk);
        end
        @(negedge aclk); s_axis_tvalid = 0; s_axis_tlast = 0;
    endtask

    task automatic send_frame();
        integer index;
        logic [31:0] random_value;
        for (index = 0; index < FRAME_WORDS; index = index + 1) begin
            random_value = random_word();
            repeat (integer'(random_value[2:0]) % 3) @(negedge aclk);
            send_word(frame_word(index), index == FRAME_WORDS-1);
        end
    endtask

    task automatic wait_first();
        integer waits;
        waits = 0;
        while (!m_axis_tvalid) begin
            @(posedge aclk); #2;
            waits = waits + 1;
            if (waits > WAIT_LIMIT) $fatal(1, "Integrated first output timed out");
        end
    endtask

    task automatic drain_output(output integer latency);
        integer waits;
        logic final_stall_tested;
        logic [31:0] random_value;
        waits = 0; final_stall_tested = 0;
        while (received < ROWS) begin
            @(negedge aclk);
            if (m_axis_tvalid && m_axis_tlast && !final_stall_tested) begin
                m_axis_tready = 0;
                repeat (7) begin @(posedge aclk); #2; end
                final_stall_tested = 1;
            end else begin
                random_value = random_word();
                m_axis_tready = random_value[3:0] < 11;
                @(posedge aclk); #2;
            end
            waits = waits + 1;
            if (waits > WAIT_LIMIT) $fatal(1, "Integrated output drain timed out");
        end
        latency = first_valid_cycle - last_input_cycle;
        @(negedge aclk); m_axis_tready = 0; model_enabled = 0;
        repeat (3) begin @(posedge aclk); #2; end
    endtask

    task automatic check_completion(input logic [31:0] sequence_value,
                                     input logic [31:0] id, generation);
        if (!irq) $fatal(1, "Completion IRQ missing");
        bus.expect_reg(12'h020, 1);
        bus.expect_reg(12'h06c, sequence_value);
        bus.expect_reg(12'h070, id);
        bus.expect_reg(12'h074, generation);
        bus.expect_reg(12'h078, 0);
        bus.expect_reg(12'h07c, 32'(FRAME_WORDS));
        bus.expect_reg(12'h080, 32'(ROWS));
        bus.expect_reg(12'h08c, 32'(golden_stalls));
        bus.expect_reg(12'h090, 0);
        bus.expect_reg(12'h094, 1);
    endtask

    logic [31:0] value, snapshot_elapsed;
    integer latency_a, latency_b, latency_d;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        rng = 32'(seed);
        reset_all();
        bus.expect_reg(12'h030, 32'(ROWS));
        bus.expect_reg(12'h034, 32'(COLS));
        bus.expect_reg(12'h038, 32'(FRAME_WORDS*4));
        bus.expect_reg(12'h03c, 32'(ROWS*4));
        bus.write_reg(12'h01c, 3, 4'h1, 0, 0, 0);

        // Job A: MMIO start, host-only timeout, and a deliberately late result.
        prepare_data();
        bus.write_reg(12'h010, 32'haaaa0001, 4'hf, 1, 2, 0);
        bus.write_reg(12'h014, 7, 4'hf, -1, 2, 0);
        bus.write_reg(12'h018, 200, 4'hf, 0, 2, 0);
        bus.write_reg(12'h008, 1, 4'h1, 0, 4, 0);
        send_frame();
        // Stage job B's settings while A remains active.
        bus.write_reg(12'h010, 32'hbbbb0002, 4'hf, -1, 0, 0);
        bus.write_reg(12'h014, 8, 4'hf, 1, 0, 0);
        bus.write_reg(12'h018, 0, 4'hf, 0, 0, 0);
        bus.write_reg(12'h008, 1, 4'h1, 0, 1, 2);
        bus.expect_reg(12'h028, 32'haaaa0001);
        bus.expect_reg(12'h02c, 7);
        repeat (20) begin @(posedge aclk); #2; end
        if (irq || m_axis_tvalid) $fatal(1, "Job A was not delayed across host timeout");
        bus.expect_reg(12'h00c, 1);
        bus.expect_reg(12'h06c, 0);
        $display("HOST_TIMEOUT_MMIO: A remains busy; staged B START rejected");
        wait_first();
        if (irq) $fatal(1, "Completion signalled before stream acceptance");
        bus.write_reg(12'h040, 1, 4'h1, 0, 0, 0);
        bus.expect_reg(12'h044, 1);
        bus.expect_reg(12'h048, 32'haaaa0001);
        bus.expect_reg(12'h04c, 7);
        bus.expect_reg(12'h050, 32'(FRAME_WORDS));
        bus.expect_reg(12'h054, 0);
        bus.expect_reg(12'h068, 1);
        bus.read_reg(12'h058, 2, 0, snapshot_elapsed);
        repeat (17) @(posedge aclk);
        bus.expect_reg(12'h058, snapshot_elapsed);
        drain_output(latency_a);
        check_completion(1, 32'haaaa0001, 7);
        bus.write_reg(12'h020, 1, 4'h0, 0, 0, 0);
        if (!irq) $fatal(1, "Zero-strobe acknowledgement lost completion");
        bus.write_reg(12'h020, 1, 4'h1, 0, 0, 0);
        if (irq) $fatal(1, "Completion acknowledgement failed");

        // Job B uses the staged settings, and A's terminal record remains readable.
        prepare_data();
        bus.write_reg(12'h008, 1, 4'h1, -1, 2, 0);
        bus.expect_reg(12'h070, 32'haaaa0001);
        bus.expect_reg(12'h028, 32'hbbbb0002);
        send_frame();
        drain_output(latency_b);
        if (latency_a - latency_b != 200)
            $fatal(1, "MMIO delay changed mid-job: A=%0d B=%0d", latency_a, latency_b);
        check_completion(2, 32'hbbbb0002, 8);
        bus.write_reg(12'h020, 1, 4'h1, 0, 0, 0);

        // Job C: early TLAST produces a sticky fault with a single terminal record.
        bus.write_reg(12'h010, 32'hcccc0003, 4'hf, 0, 0, 0);
        bus.write_reg(12'h014, 9, 4'hf, 0, 0, 0);
        bus.write_reg(12'h008, 1, 4'h1, 1, 0, 0);
        send_word(32'h12345678, 1);
        repeat (3) begin @(posedge aclk); #2; end
        if (!irq || m_axis_tvalid) $fatal(1, "Malformed frame did not report a fault");
        bus.expect_reg(12'h00c, 21);
        bus.expect_reg(12'h020, 2);
        bus.expect_reg(12'h024, 2);
        bus.expect_reg(12'h06c, 3);
        bus.expect_reg(12'h070, 32'hcccc0003);
        bus.expect_reg(12'h074, 9);
        bus.expect_reg(12'h078, 2);
        bus.expect_reg(12'h07c, 1);
        bus.expect_reg(12'h080, 0);
        bus.expect_reg(12'h094, 2);
        bus.write_reg(12'h008, 1, 4'h1, 0, 0, 2);
        bus.write_reg(12'h020, 2, 4'h1, 0, 0, 0);
        repeat (12) begin @(posedge aclk); #2; end
        if (irq) $fatal(1, "Acknowledged fault retriggered");
        bus.expect_reg(12'h00c, 5);
        bus.expect_reg(12'h06c, 3);

        // Coordinated reset of core + bus controller, then a new complete job.
        reset_all();
        prepare_data();
        bus.write_reg(12'h01c, 1, 4'h1, 0, 0, 0);
        bus.write_reg(12'h010, 32'hdddd0004, 4'hf, 0, 0, 0);
        bus.write_reg(12'h014, 10, 4'hf, 0, 0, 0);
        bus.write_reg(12'h008, 1, 4'h1, 0, 0, 0);
        send_frame();
        drain_output(latency_d);
        check_completion(1, 32'hdddd0004, 10);
        $display("PASS peripheral rows=%0d cols=%0d seed=%0d writes=%0d reads=%0d delay_delta=%0d",
                 ROWS, COLS, seed, bus.writes, bus.reads, latency_a-latency_b);
        $finish;
    end
    initial begin #100000000; $fatal(1, "Peripheral integration watchdog"); end
endmodule

`default_nettype wire
