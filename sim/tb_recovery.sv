`timescale 1ns/1ps
`default_nettype none
module tb_recovery;
    parameter integer ROWS=64,COLS=64;
    localparam integer WORDS=(ROWS+1)*COLS/4;
    logic aclk=0,aresetn=0;
    always #5 aclk=~aclk;
    `include "axil_signals.svh"
    logic [31:0] s_axis_tdata=32'h02020202;
    logic [3:0] s_axis_tkeep=15;
    logic s_axis_tvalid=0,s_axis_tlast=0,m_axis_tready=0;
    wire s_axis_tready,m_axis_tvalid,m_axis_tlast,irq;
    wire [31:0] m_axis_tdata;
    wire [3:0] m_axis_tkeep;
    kv260_matvec #(.ROWS(ROWS),.COLS(COLS)) dut(.*);
    axil_master_bfm bus(.*);
    integer received=0, sent=0, cases=0;
    logic check_data=0,stalled=0,fresh_pattern=0;
    logic [31:0] held_data;
    logic held_last;
    always @(posedge aclk) begin
        if(!aresetn) stalled=0;
        else begin
            if(stalled && (!m_axis_tvalid || m_axis_tdata!==held_data ||
                m_axis_tlast!==held_last || m_axis_tkeep!==15))
                $fatal(1,"Recovery broke held AXI-Stream beat");
            if(m_axis_tvalid && m_axis_tready) begin
                if(received>=ROWS || m_axis_tlast!==(received==ROWS-1))
                    $fatal(1,"Recovery changed packet length/TLAST");
                if(check_data && m_axis_tdata!==32'((fresh_pattern ? 20 : 6)*COLS))
                    $fatal(1,"Post-reset job has stale data");
                received=received+1;
            end
            stalled=m_axis_tvalid && !m_axis_tready;
            held_data=m_axis_tdata; held_last=m_axis_tlast;
        end
    end
    task automatic launch(input integer delay_cycles);
        @(negedge aclk); received=0;sent=0;s_axis_tkeep=15;
        bus.write_reg(12'h010,32'(cases+1),15,0,0,0);
        bus.write_reg(12'h018,32'(delay_cycles),15,0,0,0);
        bus.write_reg(12'h008,1,1,0,0,0);
    endtask
    task automatic send_one(input bit bad);
        @(negedge aclk); s_axis_tvalid=1;
        s_axis_tdata=sent<COLS/4 ? (fresh_pattern ? 32'h04040404 : 32'h02020202) :
                                 (fresh_pattern ? 32'h05050505 : 32'h03030303);
        s_axis_tkeep=bad ? 4'h7 : 4'hf;s_axis_tlast=sent==WORDS-1;
        do @(posedge aclk); while(!s_axis_tready);
        @(negedge aclk); s_axis_tvalid=0;s_axis_tlast=0;sent=sent+1;
    endtask
    task automatic remaining;
        while(sent<WORDS) send_one(0);
    endtask
    task automatic fresh_job;
        fresh_pattern=1;launch(0); check_data=1;m_axis_tready=1;remaining();
        wait(received==ROWS);repeat(4) @(negedge aclk);
        bus.write_reg(12'h020,3,1,0,0,0);
        bus.expect_reg(12'h00c,2);check_data=0;m_axis_tready=0;fresh_pattern=0;
    endtask
    initial begin
        bus.idle();repeat(4) @(negedge aclk);aresetn=1;
        bus.expect_reg(12'h0a4,3);
        // E2 must hold A upstream even if the unarmed DMA asserts TREADY.
        bus.write_reg(12'h0b0,1,1,0,0,0);
        launch(0);m_axis_tready=1;check_data=1;remaining();
        wait(dut.c_out_valid);repeat(20) @(negedge aclk);
        if(m_axis_tvalid || received || dut.stream_output_beats)
            $fatal(1,"E2 leaked source data into an unarmed receiver");
        bus.expect_reg(12'h0a8,3);
        bus.write_reg(12'h0b0,1,1,0,0,2); // Cannot introduce a gate mid-job.
        bus.write_reg(12'h010,32'hb002,15,0,0,0);
        bus.expect_reg(12'h028,1); // Source is still A despite staged B ID.
        bus.write_reg(12'h008,1,1,0,0,2);
        bus.write_reg(12'h0b0,0,1,0,0,0);
        wait(received==ROWS);repeat(4) @(negedge aclk);
        bus.write_reg(12'h020,3,1,0,0,0);
        m_axis_tready=0;check_data=0;
        for(integer scenario=0;scenario<6;scenario++) begin
            launch(scenario==1 || scenario==2 ? 1000000 : 0);
            if(scenario==0) begin
                repeat(WORDS/2) send_one(0);
            end else if(scenario==5) begin
                send_one(1); // Compute faults, supervisor must drain rest.
            end else begin
                remaining();
                if(scenario==1) wait(dut.compute.state==3); // MAC
                if(scenario==2) wait(dut.compute.state==4); // DELAY
                if(scenario==3 || scenario==4) begin
                    wait(m_axis_tvalid);
                    if(scenario==4 && ROWS>1) begin
                        @(negedge aclk);m_axis_tready=1;
                        @(posedge aclk);@(negedge aclk);m_axis_tready=0;
                    end
                end
            end
            check_data=0;
            bus.write_reg(12'h098,1,1,0,6,0);
            bus.expect_reg(12'h09c,1);
            bus.write_reg(12'h098,2,1,0,0,2); // No premature release.
            bus.write_reg(12'h008,1,1,0,0,2); // No job during reset.
            m_axis_tready=1; remaining();
            wait(received==ROWS);repeat(4) @(negedge aclk);
            bus.expect_reg(12'h09c,3);
            repeat(20) @(negedge aclk); // Model DDR/callback wait.
            bus.expect_reg(12'h0a0,32'(cases));
            if(dut.core_aresetn) $fatal(1,"Released reset before driver approval");
            bus.write_reg(12'h098,2,1,0,6,0);
            bus.write_reg(12'h020,3,1,0,0,0);
            cases=cases+1;bus.expect_reg(12'h0a0,32'(cases));
            bus.expect_reg(12'h09c,0);bus.expect_reg(12'h00c,2);
            m_axis_tready=0;fresh_job();
        end
        $display("PASS recovery rows=%0d cols=%0d abort_phases=%0d post_reset_jobs=%0d e2_gate=1",ROWS,COLS,cases,cases);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Recovery watchdog");end
endmodule
`default_nettype wire
