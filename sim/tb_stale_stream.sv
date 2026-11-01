`timescale 1ns/1ps
`default_nettype none
// E2: receiver-only reset leaves A's held AXI-Stream output alive.
// Descriptor identity alone cannot authenticate that untagged payload.
module tb_stale_stream;
    parameter integer ROWS=64, COLS=64;
    logic aclk=0, aresetn=0, dma_resetn=0;
    always #5 aclk=~aclk;
    logic start_valid=0;
    wire start_ready;
    logic [31:0] cfg_job_id=0, cfg_generation=0, cfg_delay_cycles=0;
    logic [31:0] s_axis_tdata=0;
    logic [3:0] s_axis_tkeep=15;
    logic s_axis_tvalid=0, s_axis_tlast=0;
    wire s_axis_tready;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    wire m_axis_tvalid,m_axis_tready,m_axis_tlast,busy,done,fault;
    wire [2:0] error_code;
    wire [31:0] active_job_id,active_generation,input_beats,output_beats;
    wire [63:0] elapsed_cycles,output_stall_cycles;
    `include "axi_write_signals.svh"
    logic arm_valid=0;
    wire arm_ready;
    logic [31:0] arm_job_id=0, arm_generation=0;
    wire dma_active,dma_done,dma_fault;
    wire [2:0] dma_error;
    wire [31:0] dma_job_id,generation,stream_beats,written_beats;
    wire idle,pending_write,commit_valid,commit_success;
    wire [31:0] commit_address,commit_data;
    wire [3:0] commit_strobes;
    integer fd, policy, stale_words;
    axis_int8_matvec #(.ROWS(ROWS),.COLS(COLS)) core (.*);
    s2mm_write_model dma (
        .aclk(aclk),.aresetn(dma_resetn),.arm_valid(arm_valid),.arm_ready(arm_ready),
        .arm_address(32'h1000),.arm_words(32'(ROWS)),.arm_job_id(arm_job_id),
        .arm_generation(arm_generation),.arm_write_delay(32'd3),.allow_bready(1'b1),
        .s_axis_tdata(m_axis_tdata),.s_axis_tkeep(m_axis_tkeep),.s_axis_tvalid(m_axis_tvalid),
        .s_axis_tlast(m_axis_tlast),.s_axis_tready(m_axis_tready),.active(dma_active),
        .done(dma_done),.fault(dma_fault),.error_code(dma_error),.job_id(dma_job_id),.*
    );
    axi_write_ram_model #(.WORDS(ROWS+8)) ram (
        .allow_aw(1'b1),.allow_w(1'b1),.commit_enable(1'b1),.response_delay(32'd5),.*
    );
    axi_write_checker check_axi (.*);
    function automatic [31:0] expected(input bit b, input integer row);
        return b ? 32'(2*COLS*(3+row%5)) : 32'(-3*COLS*(1+row%64));
    endfunction
    task automatic launch(input bit b);
        @(negedge aclk);
        if (!start_ready) $fatal(1,"Source not clean before launch");
        cfg_job_id=b ? 32'hb002 : 32'ha001; cfg_generation=b ? 2 : 1; start_valid=1;
        @(posedge aclk); @(negedge aclk); start_valid=0;
        for(integer word_index=0;word_index<(ROWS+1)*COLS/4;word_index++) begin
            for(integer lane=0;lane<4;lane++) begin
                if(word_index*4+lane<COLS) s_axis_tdata[8*lane+:8]=b ? 8'd2 : -8'd3;
                else s_axis_tdata[8*lane+:8]=b ? 8'(3+((word_index*4+lane-COLS)/COLS)%5) :
                    8'(1+((word_index*4+lane-COLS)/COLS)%64);
            end
            s_axis_tlast=word_index==(ROWS+1)*COLS/4-1; s_axis_tvalid=1;
            do @(posedge aclk); while(!s_axis_tready);
            @(negedge aclk);
        end
        s_axis_tvalid=0; s_axis_tlast=0;
    endtask
    task automatic arm(input bit b);
        @(negedge aclk);
        if(!arm_ready) $fatal(1,"Receiver busy");
        arm_job_id=b ? 32'hb002 : 32'ha001; arm_generation=b ? 2 : 1; arm_valid=1;
        @(posedge aclk); @(negedge aclk); arm_valid=0;
    endtask
    task automatic drained;
        wait(dma_done); @(negedge aclk);
        if(dma_fault || fault || dma_active || !idle || !start_ready || written_beats!=ROWS)
            $fatal(1,"Incomplete stream/drain");
    endtask
    initial begin
        fd=$fopen($sformatf("build/stale_%0dx%0d.jsonl",ROWS,COLS),"w");
        if(!fd) $fatal(1,"Cannot open E2 metrics");
        for(policy=0;policy<3;policy++) begin
            @(negedge aclk); aresetn=0; dma_resetn=0;
            repeat(4) @(negedge aclk);
            aresetn=1; dma_resetn=1;
            for(integer r=0;r<ROWS+8;r++) ram.cpu_write(r,32'hc0ffee00^32'(r));
            launch(0);
            // A has not handshaken a single output. Timeout while held VALID.
            wait(m_axis_tvalid); repeat(10) @(negedge aclk);
            if(output_beats!=0 || !busy) $fatal(1,"E2 window not reached");
            if(policy<2) begin
                dma_resetn=0; repeat(4) @(negedge aclk); dma_resetn=1;
                // Core is deliberately not reset: old payload remains.
                arm(1); drained(); stale_words=0;
                if(dma_job_id!=32'hb002 || generation!=2 || active_job_id!=32'ha001)
                    $fatal(1,"E2 identity setup failed");
                for(integer r=0;r<ROWS;r++) begin
                    if(ram.cpu_read(r)!==expected(0,r)) $fatal(1,"Missing stale payload");
                    if(ram.cpu_read(r)!==expected(1,r)) stale_words++;
                end
            end else begin
                // Retain A's destination until both source and sink drain.
                arm(0); drained();
                arm(1); launch(1); drained(); stale_words=0;
                for(integer r=0;r<ROWS;r++)
                    if(ram.cpu_read(r)!==expected(1,r)) $fatal(1,"P2 stale payload");
            end
            for(integer r=ROWS;r<ROWS+8;r++)
                if(ram.cpu_read(r)!==(32'hc0ffee00^32'(r))) $fatal(1,"E2 guard changed");
            $fwrite(fd,"{\"rows\":%0d,\"cols\":%0d,\"policy\":\"P%0d\",\"stale_words\":%0d,\"descriptor_matches_b\":1,\"guard_errors\":0}\n",ROWS,COLS,policy,stale_words);
            // Independent normal follow-up after unsafe positive controls.
            if(policy<2) begin
                arm(1); launch(1); drained();
                for(integer r=0;r<ROWS;r++)
                    if(ram.cpu_read(r)!==expected(1,r)) $fatal(1,"E2 follow-up incorrect");
            end
        end
        $fclose(fd);
        $display("PASS stale-stream rows=%0d cols=%0d policies=3",ROWS,COLS); $finish;
    end
    initial begin #1000000000; $fatal(1,"E2 watchdog"); end
endmodule
`default_nettype wire
