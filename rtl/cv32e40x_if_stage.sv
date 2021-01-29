// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Renzo Andri - andrire@student.ethz.ch                      //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                                                                            //
// Design Name:    Instruction Fetch Stage                                    //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Instruction fetch unit: Selection of the next PC, and      //
//                 buffering (sampling) of the read instruction               //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_if_stage import cv32e40x_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Used to calculate the exception offsets
    input  logic [23:0] mtvec_addr,

    // Boot address
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] dm_exception_addr_i,

    // Debug mode halt address
    input  logic [31:0] dm_halt_addr_i,

    // instruction request control
    input  logic        req_i,

    // instruction cache interface
    if_obi_instr.master  m_obi_instr_if,

    // Output of IF Pipeline stage
    output if_id_pipe_t       if_id_pipe_o,

    output logic       [31:0] pc_if_o,

    // Forwarding ports - control signals
    input  logic        clear_instr_valid_i,   // clear instruction valid bit in IF/ID pipe
    input  logic        pc_set_i,              // set the program counter to a new value
    input  logic [31:0] mepc_i,                // address used to restore PC when the interrupt/exception is served

    input  logic [31:0] dpc_i,                // address used to restore PC when the debug is served

    input  pc_mux_e     pc_mux_i,              // sel for pc multiplexer
    input  exc_pc_mux_e exc_pc_mux_i,          // selects ISR address

    input  logic  [4:0] m_exc_vec_pc_mux_i,    // selects ISR address for vectorized interrupt lines
    output logic        csr_mtvec_init_o,      // tell CS regfile to init mtvec

    // jump and branch target and decision
    input  logic [31:0] jump_target_id_i,      // jump target address
    input  logic [31:0] jump_target_ex_i,      // jump target address

    // pipeline stall
    input  logic        halt_if_i,
    input  logic        id_ready_i,

    // misc signals
    output logic        if_busy_o,             // is the IF stage busy fetching instructions?
    output logic        perf_imiss_o           // Instruction Fetch Miss
);
  
  logic              if_valid, if_ready;

  // prefetch buffer related signals
  logic              prefetch_busy;
  logic              branch_req;
  logic       [31:0] branch_addr_n;

  logic              fetch_valid;
  logic              fetch_ready;
  logic       [31:0] fetch_rdata;

  logic       [31:0] exc_pc;

  logic              fetch_failed;

  logic              aligner_ready;
  logic              instr_valid;

  logic              illegal_c_insn;
  logic [31:0]       instr_aligned;
  logic [31:0]       instr_decompressed;
  logic              instr_compressed_int;

  // exception PC selection mux
  always_comb
  begin : EXC_PC_MUX
    unique case (exc_pc_mux_i)
      EXC_PC_EXCEPTION:                        exc_pc = { mtvec_addr, 8'h0 }; //1.10 all the exceptions go to base address
      EXC_PC_IRQ:                              exc_pc = { mtvec_addr, 1'b0, m_exc_vec_pc_mux_i, 2'b0 }; // interrupts are vectored
      EXC_PC_DBD:                              exc_pc = { dm_halt_addr_i[31:2], 2'b0 };
      EXC_PC_DBE:                              exc_pc = { dm_exception_addr_i[31:2], 2'b0 };
      default:                                 exc_pc = { mtvec_addr, 8'h0 };
    endcase
  end

  // fetch address selection
  always_comb
  begin
    // Default assign PC_BOOT (should be overwritten in below case)
    branch_addr_n = {boot_addr_i[31:2], 2'b0};

    unique case (pc_mux_i)
      PC_BOOT:      branch_addr_n = {boot_addr_i[31:2], 2'b0};
      PC_JUMP:      branch_addr_n = jump_target_id_i;
      PC_BRANCH:    branch_addr_n = jump_target_ex_i;
      PC_EXCEPTION: branch_addr_n = exc_pc;             // set PC to exception handler
      PC_MRET:      branch_addr_n = mepc_i; // PC is restored when returning from IRQ/exception
      PC_DRET:      branch_addr_n = dpc_i; //
      PC_FENCEI:    branch_addr_n = if_id_pipe_o.pc + 4; // jump to next instr forces prefetch buffer reload
      default:;
    endcase
  end

  // tell CS register file to initialize mtvec on boot
  assign csr_mtvec_init_o = (pc_mux_i == PC_BOOT) & pc_set_i;

  assign fetch_failed    = 1'b0; // PMP is not supported in CV32E40P

  // prefetch buffer, caches a fixed number of instructions
  cv32e40x_prefetch_buffer prefetch_buffer_i
  (
    .clk               ( clk                         ),
    .rst_n             ( rst_n                       ),

    .req_i             ( req_i                       ),

    .branch_i          ( branch_req                  ),
    .branch_addr_i     ( {branch_addr_n[31:1], 1'b0} ),

    .fetch_ready_i     ( fetch_ready                 ),
    .fetch_valid_o     ( fetch_valid                 ),
    .fetch_rdata_o     ( fetch_rdata                 ),

    // goes to instruction memory / instruction cache
    .m_obi_instr_if     ( m_obi_instr_if             ),

    // Prefetch Buffer Status
    .busy_o            ( prefetch_busy               )
);

  // offset FSM state transition logic
  always_comb
  begin

    fetch_ready   = 1'b0;
    branch_req    = 1'b0;
    // take care of jumps and branches
    if (pc_set_i) begin
      branch_req    = 1'b1;
    end
    else if (fetch_valid) begin
      if (req_i && if_valid) begin
        fetch_ready   = aligner_ready;
      end
    end
  end

  assign if_busy_o    = prefetch_busy;
  assign perf_imiss_o = !fetch_valid && !branch_req;

  // IF-ID pipeline registers, frozen when the ID stage is stalled
  always_ff @(posedge clk, negedge rst_n)
  begin : IF_ID_PIPE_REGISTERS
    if (rst_n == 1'b0)
    begin
      if_id_pipe_o.instr_valid     <= 1'b0;
      if_id_pipe_o.instr_rdata     <= '0;
      if_id_pipe_o.is_fetch_failed <= 1'b0;
      if_id_pipe_o.pc              <= '0;
      if_id_pipe_o.is_compressed   <= 1'b0;
      if_id_pipe_o.illegal_c_insn  <= 1'b0;
    end
    else
    begin

      if (if_valid && instr_valid)
      begin
        if_id_pipe_o.instr_valid     <= 1'b1;
        if_id_pipe_o.instr_rdata     <= instr_decompressed;
        if_id_pipe_o.is_compressed   <= instr_compressed_int;
        if_id_pipe_o.illegal_c_insn  <= illegal_c_insn;
        if_id_pipe_o.is_fetch_failed <= 1'b0;
        if_id_pipe_o.pc              <= pc_if_o;
      end else if (clear_instr_valid_i) begin
        if_id_pipe_o.instr_valid     <= 1'b0;
        if_id_pipe_o.is_fetch_failed <= fetch_failed;
      end
    end
    end

  assign if_ready = fetch_valid & id_ready_i;
  assign if_valid = (~halt_if_i) & if_ready;

  cv32e40x_aligner aligner_i
  (
    .clk               ( clk                          ),
    .rst_n             ( rst_n                        ),
    .fetch_valid_i     ( fetch_valid                  ),
    .aligner_ready_o   ( aligner_ready                ),
    .if_valid_i        ( if_valid                     ),
    .fetch_rdata_i     ( fetch_rdata                  ),
    .instr_aligned_o   ( instr_aligned                ),
    .instr_valid_o     ( instr_valid                  ),
    .branch_addr_i     ( {branch_addr_n[31:1], 1'b0}  ),
    .branch_i          ( branch_req                   ),
    .pc_o              ( pc_if_o                      )
  );

  cv32e40x_compressed_decoder
  compressed_decoder_i
  (
    .instr_i         ( instr_aligned        ),
    .instr_o         ( instr_decompressed   ),
    .is_compressed_o ( instr_compressed_int ),
    .illegal_instr_o ( illegal_c_insn       )
  );

  //----------------------------------------------------------------------------
  // Assertions
  //----------------------------------------------------------------------------

`ifdef CV32E40P_ASSERT_ON



`endif

endmodule
