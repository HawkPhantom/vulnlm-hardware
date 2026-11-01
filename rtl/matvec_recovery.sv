`timescale 1ns/1ps
`default_nettype none
// Abort only the compute datapath. Keep AXI-Lite and the DMA/DDR fabric alive.
// Finish the existing fixed-size DMA packets with discarded input/padding;
// the driver must observe DMA completion before RELEASE permits another job.
module matvec_recovery #(parameter integer ROWS=64, COLS=64) (
    input wire aclk, aresetn, job_start, abort_drain, recovery_release, receive_hold,
    output logic recovery_active, output wire recovery_drained,
    output logic [31:0] recovery_count,
    output wire core_aresetn,
    output wire [31:0] stream_state, output logic [31:0] stream_output_beats,
    input wire [31:0] s_axis_tdata, input wire [3:0] s_axis_tkeep,
    input wire s_axis_tvalid, s_axis_tlast, output wire s_axis_tready,
    output wire [31:0] c_in_data, output wire [3:0] c_in_keep,
    output wire c_in_valid, c_in_last, input wire c_in_ready,
    input wire [31:0] c_out_data, input wire [3:0] c_out_keep,
    input wire c_out_valid, c_out_last, output wire c_out_ready,
    output wire [31:0] m_axis_tdata, output wire [3:0] m_axis_tkeep,
    output wire m_axis_tvalid, m_axis_tlast, input wire m_axis_tready
);
    localparam integer INPUT_WORDS=(ROWS+1)*COLS/4;
    logic [31:0] input_beats;
    logic job_active, drain_job, held_valid;
    logic [31:0] held_data;
    logic [3:0] held_keep;
    logic held_last;
    assign core_aresetn=aresetn && !recovery_active;
    assign recovery_drained=recovery_active && (!drain_job ||
        (input_beats==INPUT_WORDS && stream_output_beats==ROWS));
    assign stream_state={29'd0, stream_output_beats==ROWS,
                         input_beats==INPUT_WORDS, recovery_active ? m_axis_tvalid : c_out_valid};
    assign c_in_data=s_axis_tdata;
    assign c_in_keep=s_axis_tkeep;
    assign c_in_last=s_axis_tlast;
    assign c_in_valid=s_axis_tvalid && !recovery_active;
    assign s_axis_tready=aresetn && (recovery_active ?
        (drain_job && input_beats<INPUT_WORDS) : c_in_ready);
    assign c_out_ready=m_axis_tready && !recovery_active && !receive_hold;
    assign m_axis_tvalid=aresetn && (recovery_active ?
        (drain_job && stream_output_beats<ROWS) : (c_out_valid && !receive_hold));
    assign m_axis_tdata=recovery_active ? (held_valid ? held_data : 32'd0) : c_out_data;
    assign m_axis_tkeep=recovery_active ? (held_valid ? held_keep : 4'hf) : c_out_keep;
    assign m_axis_tlast=recovery_active ? (held_valid ? held_last : stream_output_beats==ROWS-1) : c_out_last;
    always_ff @(posedge aclk) begin
        if(!aresetn) begin
            recovery_active<=0; recovery_count<=0; input_beats<=0;
            stream_output_beats<=0; job_active<=0; drain_job<=0;
            held_valid<=0; held_data<=0; held_keep<=0; held_last<=0;
        end else begin
            if(job_start && !recovery_active) begin
                input_beats<=0; stream_output_beats<=0; job_active<=1;
            end
            if(s_axis_tvalid && s_axis_tready) input_beats<=input_beats+1;
            if(m_axis_tvalid && m_axis_tready) begin
                stream_output_beats<=stream_output_beats+1;
                if(stream_output_beats==ROWS-1) job_active<=0;
                if(recovery_active) held_valid<=0;
            end
            if(abort_drain && !recovery_active) begin
                recovery_active<=1; drain_job<=job_active;
                // A stalled valid beat cannot change even on a local reset.
                held_valid<=c_out_valid && !m_axis_tready;
                held_data<=c_out_data; held_keep<=c_out_keep; held_last<=c_out_last;
            end
            if(recovery_release && recovery_drained) begin
                recovery_active<=0; held_valid<=0; drain_job<=0; job_active<=0;
                recovery_count<=recovery_count+1;
            end
        end
    end
endmodule
`default_nettype wire
