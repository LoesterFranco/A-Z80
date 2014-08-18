//============================================================================
// Module execute in control/decode Z80 CPU
//
// Copyright 2014 Goran Devic
//
// This module implements the instruction execute state logic.
//============================================================================
`timescale 1ns/ 100 ps

module execute
(
    //----------------------------------------------------------
    // Control signals generated by the instruction execution
    //----------------------------------------------------------
    `include "exec_module.i"

    output logic nextM,
    output logic setM1,
    
    output logic fFetch,
    output logic fMRead,
    output logic fMWrite,
    output logic fIORead,
    output logic fIOWrite,
    
    //----------------------------------------------------------
    // Inputs from the instruction decode PLA
    //----------------------------------------------------------
    input wire [104:0] pla,             // Statically decoded instructions

    //----------------------------------------------------------
    // Inputs from various blocks
    //----------------------------------------------------------
    input wire reset,
    input wire clk,
    input wire in_intr,                 // Servicing maskable interrupt
    input wire in_nmi,                  // Servicing non-maskable interrupt
    input wire im1,                     // Interrupt Mode 1
    input wire im2,                     // Interrupt Mode 2
    input wire use_ixiy,                // Special decode signal
    
    //----------------------------------------------------------
    // Machine and clock cycles
    //----------------------------------------------------------
    input wire M1,                      // Machine cycle #1
    input wire M2,                      // Machine cycle #2
    input wire M3,                      // Machine cycle #3
    input wire M4,                      // Machine cycle #4
    input wire M5,                      // Machine cycle #5
    input wire M6,                      // Machine cycle #6
    input wire T1,                      // T-cycle #1
    input wire T2,                      // T-cycle #2
    input wire T3,                      // T-cycle #3
    input wire T4,                      // T-cycle #4
    input wire T5,                      // T-cycle #5
    input wire T6                       // T-cycle #6
);

// If set by the execution matrix, prevents looping back to the next instruction
// Instructions that are longer than 4T set this at M1/T4
logic contM1;                           // Continue M1 cycle
// Instructions that use M2 immediately after M1/T4 set this at M1/T4
logic contM2;                           // Continue with the next M cycle

`define GP_REG_AF       2'h3

`define FLAGS_ALL_SEL   ctl_flags_sz_we=1; ctl_flags_xy_we=1; ctl_flags_hf_we=1; ctl_flags_pf_we=1; ctl_flags_nf_we=1; ctl_flags_cf_we=1; 

//----------------------------------------------------------
// Make available different sections of the opcode byte
//----------------------------------------------------------
wire [1:0] op54;
wire [1:0] op43;
wire op5;
wire op3;

assign op54 = { pla[104], pla[103] };
assign op43 = { pla[103], pla[102] };
assign op5 = pla[104];
assign op3 = pla[102];

always_comb
begin
    //----------------------------------------------------------
    // Default assignment of all control outputs to 0 to prevent the
    // generation of latches
    //----------------------------------------------------------
    `include "exec_zero.i"

    // Reset internal control wires
    contM1 = 0; contM2 = 0;
    nextM = 0;  setM1 = 0;
    // Reset global machine cycle function
    fFetch = 0; fMRead = 0; fMWrite = 0; fIORead = 0; fIOWrite = 0;  
    
    //----------------------------------------------------------
    // Reset control: Set PC and IR to 0
    //----------------------------------------------------------
    if (reset) begin
        ctl_inc_zero = 1;               // Force 0 to the output of incrementer
        ctl_bus_inc_we = 1;             // Incrementer to the abus
        ctl_reg_sel_pc = clk;           // Write to the PC on clock up
        ctl_reg_sel_ir = !clk;          // Write to the IR on clock down
        ctl_reg_sys_we = 1;             // Perform write
        ctl_reg_sys_hilo = 2'b11;       // 16-bit width & write
    end
    
    //----------------------------------------------------------
    // State-based signal assignment
    //----------------------------------------------------------
    `include "exec_matrix.i"

    //========================================================================
    // Default M1 fetch cycle execution
    //========================================================================
    // M1 is always a fetch phase
    if (M1) fFetch = 1;

    //----------------------------------------------------------
    // T1:  PC => AB
    if (M1 && T1) begin
        ctl_reg_sel_pc = 1;             // Select PC
        ctl_reg_sys_hilo = 2'b11;       // 16-bit width
        ctl_al_we = 1;                  // Write it into the address latch
    end
    
    //----------------------------------------------------------
    // T2:  increment AL and write it back to PC
    //      Read opcode from external data pins into the data latch
    if (M1 && T2) begin
        ctl_inc_cy = 1;                 // Increment address latch
        ctl_bus_inc_we = 1;             // Incrementer to the abus

        ctl_reg_sel_pc = 1;             // Select PC
        ctl_reg_sys_hilo = 2'b11;       // 16-bit width
        ctl_reg_sys_we = 1;             // Write 16-bit PC
    
        ctl_bus_db_oe = 1;              // Data pin latch to internal data bus, unless:
        // When servicing interrupts, depending on the interrupt mode:
        // IM0 : (nothing special here)
        // IM1 : Force FF on the bus and execute it (RST38 instruction)
        // IM2 : Force 00 on the bus - later we execute a special CALL on that NOP
        // NMI : Force FF on the bus and execute it (RST38 instruction)
        //       within the RST instruction the target address is conditionally set to 0x66
        if ((in_intr && im1) || in_nmi) ctl_bus_ff_oe = 1;
        if (in_intr && im2) ctl_bus_zero_oe = 1;
    end

    //----------------------------------------------------------
    // T3:  IR => AB        SW4=OFF
    //      AF => ALU       SW1=OFF
    //      Read opcode byte from the data latch into the IR
    if (M1 && T3) begin
        ctl_reg_sel_ir = 1;             // Select IR
        ctl_reg_sys_hilo = 2'b11;       // 16-bit width
        ctl_al_we = 1;                  // Write it into the address latch
        
        ctl_reg_gp_sel = `GP_REG_AF;    // Select AF
        ctl_reg_gp_hilo = 2'b11;        // 16-bit width
                                        // Read AF onto the data bus

        ctl_alu_shift_oe = 1;           // ALU input through the shifter
        ctl_alu_op1_sel_bus = 1;        // Acc=>OP1
        ctl_alu_op2_sel_bus = 1;        // Acc=>OP2
        ctl_flags_bus = 1;              // F=>FLAGT
        `FLAGS_ALL_SEL                  // Select all flags
        
        ctl_bus_db_oe = 1;              // Output opcode from the DB latch
        ctl_ir_we = 1;                  // Write the opcode into the instruction register
    end

    //----------------------------------------------------------
    // T4:  increment and write back to R
    //
    // At T4, evaluate continuation flags for some instructions that need more than 4T
    if (M1 && T4) begin
        ctl_inc_cy = 1;                 // Increment address latch
        ctl_inc_dec = 1; // TEST: Decrement R !
        ctl_inc_limit6 = 1;             // Limit the incrementer to 6 bits
        ctl_bus_inc_we = 1;             // Incrementer to the abus

        ctl_reg_sel_ir = 1;             // Select IR
        ctl_reg_sys_hilo = 2'b11;       // 16-bit width
        ctl_reg_sys_we = 1;             // Write 16-bit IR

        nextM = !contM1;
        setM1 = !contM1 & !contM2;
    end
end

endmodule
