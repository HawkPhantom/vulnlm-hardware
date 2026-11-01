`timescale 1ns/1ps
`default_nettype none

// One job at a time. Frame: packed x, then row-major W; four INT8s/beat.
// All input must arrive and pass framing checks before any result is emitted.
module axis_int8_matvec #(
    parameter integer ROWS = 64,
    parameter integer COLS = 64
) (
    input  wire          aclk,
    input  wire          aresetn,

    input  wire          start_valid,
    output wire          start_ready,
    input  wire [31:0]   cfg_job_id,
    input  wire [31:0]   cfg_generation,
    input  wire [31:0]   cfg_delay_cycles,

    input  wire [31:0]   s_axis_tdata,
    input  wire [3:0]    s_axis_tkeep,
    input  wire          s_axis_tvalid,
    output wire          s_axis_tready,
    input  wire          s_axis_tlast,

    output wire [31:0]   m_axis_tdata,
    output wire [3:0]    m_axis_tkeep,
    output wire          m_axis_tvalid,
    input  wire          m_axis_tready,
    output wire          m_axis_tlast,

    output wire          busy,
    output logic         done,
    output wire          fault,
    output logic [2:0]   error_code,
    output logic [31:0]  active_job_id,
    output logic [31:0]  active_generation,
    output logic [31:0]  input_beats,
    output logic [31:0]  output_beats,
    output logic [63:0]  elapsed_cycles,
    output logic [63:0]  output_stall_cycles
);
    localparam integer X_WORDS = COLS / 4;
    localparam integer W_WORDS = ROWS * X_WORDS;
    localparam integer FRAME_WORDS = X_WORDS + W_WORDS;
    localparam integer RX_BITS = (FRAME_WORDS > 1) ? $clog2(FRAME_WORDS) : 1;
    localparam integer W_BITS = (W_WORDS > 1) ? $clog2(W_WORDS) : 1;
    localparam integer ROW_BITS = (ROWS > 1) ? $clog2(ROWS) : 1;
    localparam integer COL_BITS = (COLS > 1) ? $clog2(COLS) : 1;

    localparam logic [2:0] ERR_NONE = 3'd0;
    localparam logic [2:0] ERR_KEEP = 3'd1;
    localparam logic [2:0] ERR_EARLY_LAST = 3'd2;
    localparam logic [2:0] ERR_MISSING_LAST = 3'd3;
    localparam logic [2:0] ERR_STATE = 3'd4;

    typedef enum logic [2:0] {
        IDLE, RECEIVE, FETCH, MAC, DELAY, SEND, FAULTED
    } state_t;
    state_t state;

    // No reset on memories: every job must reload its complete input frame.
    // Word-wide writes and registered reads permit synchronous RAM inference.
    logic [31:0] x_words [0:X_WORDS-1];
    logic [31:0] w_words [0:W_WORDS-1];
    logic [31:0] x_read, w_read;
    logic [RX_BITS-1:0] rx_index;
    logic [W_BITS-1:0] w_index;
    logic [ROW_BITS-1:0] row_index;
    logic [COL_BITS-1:0] col_index;
    logic signed [31:0] accumulator;
    logic [31:0] result_data;
    logic [31:0] delay_remaining;
    wire signed [7:0] x_element = $signed(x_read[col_index[1:0]*8 +: 8]);
    wire signed [7:0] w_element = $signed(w_read[col_index[1:0]*8 +: 8]);
    wire signed [15:0] product = x_element * w_element;
    wire signed [31:0] extended_product = {{16{product[15]}}, product};
    wire signed [31:0] mac_sum = accumulator + extended_product;

    assign start_ready = aresetn && (state == IDLE);
    assign s_axis_tready = aresetn && (state == RECEIVE);
    assign m_axis_tvalid = aresetn && (state == SEND);
    assign m_axis_tdata = result_data;
    assign m_axis_tkeep = 4'b1111;
    assign m_axis_tlast = (state == SEND) && (row_index == ROWS-1);
    assign busy = (state != IDLE);
    assign fault = (state == FAULTED);

    // These are elaboration constraints, not runtime request validation.
    initial begin
        if (ROWS < 1 || ROWS > 4096 || COLS < 4 || COLS > 4096 || COLS % 4 != 0)
            $fatal(1, "ROWS must be 1..4096; COLS must be 4..4096 and divisible by 4");
    end

    // Active-low synchronous reset. A system reset must also reset/flush the
    // connected stream source, FIFOs and DMA; this core cannot revoke DMA writes.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE;
            done <= 1'b0;
            error_code <= ERR_NONE;
            active_job_id <= '0;
            active_generation <= '0;
            input_beats <= '0;
            output_beats <= '0;
            elapsed_cycles <= '0;
            output_stall_cycles <= '0;
            rx_index <= '0;
            w_index <= '0;
            row_index <= '0;
            col_index <= '0;
            accumulator <= '0;
            result_data <= '0;
            delay_remaining <= '0;
            x_read <= '0;
            w_read <= '0;
        end else begin
            done <= 1'b0;
            if (state != IDLE && state != FAULTED)
                elapsed_cycles <= elapsed_cycles + 64'd1;
            if (m_axis_tvalid && !m_axis_tready)
                output_stall_cycles <= output_stall_cycles + 64'd1;

            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        active_job_id <= cfg_job_id;
                        active_generation <= cfg_generation;
                        delay_remaining <= cfg_delay_cycles;
                        input_beats <= '0;
                        output_beats <= '0;
                        elapsed_cycles <= '0;
                        output_stall_cycles <= '0;
                        error_code <= ERR_NONE;
                        rx_index <= '0;
                        w_index <= '0;
                        row_index <= '0;
                        col_index <= '0;
                        accumulator <= '0;
                        state <= RECEIVE;
                    end
                end

                RECEIVE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        input_beats <= input_beats + 32'd1;
                        if (s_axis_tkeep != 4'b1111) begin
                            error_code <= ERR_KEEP;
                            state <= FAULTED;
                        end else if (s_axis_tlast && rx_index != FRAME_WORDS-1) begin
                            error_code <= ERR_EARLY_LAST;
                            state <= FAULTED;
                        end else if (!s_axis_tlast && rx_index == FRAME_WORDS-1) begin
                            error_code <= ERR_MISSING_LAST;
                            state <= FAULTED;
                        end else begin
                            if (rx_index < X_WORDS)
                                x_words[rx_index] <= s_axis_tdata;
                            else
                                w_words[rx_index-X_WORDS] <= s_axis_tdata;
                            if (rx_index == FRAME_WORDS-1)
                                state <= FETCH;
                            else
                                rx_index <= rx_index + 1'b1;
                        end
                    end
                end

                FETCH: begin
                    x_read <= x_words[col_index >> 2];
                    w_read <= w_words[w_index];
                    state <= MAC;
                end

                MAC: begin
                    if (col_index[1:0] == 2'b11 && w_index != W_WORDS-1)
                        w_index <= w_index + 1'b1;
                    if (col_index == COLS-1) begin
                        result_data <= mac_sum;
                        // Delay only the first output beat; never retract VALID.
                        if (row_index == 0 && delay_remaining != 0)
                            state <= DELAY;
                        else
                            state <= SEND;
                    end else begin
                        accumulator <= mac_sum;
                        col_index <= col_index + 1'b1;
                        state <= FETCH;
                    end
                end

                DELAY: begin
                    if (delay_remaining == 32'd1) begin
                        delay_remaining <= '0;
                        state <= SEND;
                    end else begin
                        delay_remaining <= delay_remaining - 32'd1;
                    end
                end

                SEND: begin
                    // Result, row and TLAST remain unchanged under backpressure.
                    if (m_axis_tvalid && m_axis_tready) begin
                        output_beats <= output_beats + 32'd1;
                        if (row_index == ROWS-1) begin
                            done <= 1'b1;
                            state <= IDLE;
                        end else begin
                            row_index <= row_index + 1'b1;
                            col_index <= '0;
                            accumulator <= '0;
                            state <= FETCH;
                        end
                    end
                end

                FAULTED: begin
                    // No automatic restart or packet resynchronization.
                    // The controller must coordinate a full datapath reset.
                    state <= FAULTED;
                end

                default: begin
                    error_code <= ERR_STATE;
                    state <= FAULTED;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
