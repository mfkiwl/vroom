//
// RVOOM! Risc-V superscalar O-O
// Copyright (C) 2019-22 Paul Campbell - paul@taniwha.com
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 

module rename_ctrl(
		input		clk, 
		input		reset,
`ifdef TRACE_CACHE
		input		trace_used,
`endif
		input   [2*NDEC-1:0]will_be_valid,
		input	[LNCOMMIT:0]current_available,
		input			    commit_br_enable,
		input				commit_trap_br_enable,
		input				commit_int_force_fetch,

		output				force_fetch_rename,

		output  [LNCOMMIT-1:0]count_out,
		output  [3:0]rename_count_out,
		output 	    proceed,
		output		rename_reloading,
		output	    rename_stall);
        parameter VA_SZ=48;
        parameter CNTRL_SIZE=7;
        parameter NDEC = 4; // number of decode stages
        parameter NHART=1;      
        parameter LNHART=0;      
        parameter BDEC= 4;
		parameter RA=5;
		parameter RV=64;
		parameter HART=0;
		parameter NCOMMIT = 32; // number of commit registers 
        parameter LNCOMMIT = 5; // number of bits to encode that
		parameter CALL_STACK_SIZE=32;
		parameter NUM_PENDING=32;
		parameter NUM_PENDING_RET=8;

	reg [LNCOMMIT-1:0]c_count_out;
	assign proceed = !rename_stall && c_count_out > 0;
	assign count_out = (reset?0:commit_int_force_fetch?2:rename_reloading|| c_count_out > current_available?0:c_count_out);
	assign rename_stall = !reset && c_count_out > current_available;
	wire stall_in = commit_br_enable|commit_trap_br_enable|r_force_fetch_rename;
	reg [1:0]r_stall;
	reg [3:0]r_count_out;
	always @(posedge clk)
		r_count_out <= (reset?0:count_out);
	assign rename_count_out = r_count_out;	// 1 clock later for accounting


	reg		r_force_fetch_rename;
	always @(posedge clk)
		r_force_fetch_rename <= commit_int_force_fetch;
	assign force_fetch_rename = r_force_fetch_rename;

	generate
		if (NDEC==2) begin
`include "mk8_4.inc"
		end else
		if (NDEC==4) begin
`include "mk8_8.inc"
		end else
		if (NDEC==8) begin
`include "mk8_16.inc"
		end 
	endgenerate

`ifdef TRACE_CACHE
	assign rename_reloading = (trace_used? r_stall[0]|stall_in :  r_stall!=0);
`else
	assign rename_reloading = r_stall!=0;
`endif
    always @(posedge clk)
		r_stall <= (reset||commit_int_force_fetch?0:{r_stall[0], stall_in});

endmodule

module scoreboard(
		input			clk, 
		input			reset,

		input			rename_valid,
		input [LNCOMMIT-1:0]rename_result,
`ifdef RENAME_OPT
		input			rename_is_0,
		input			rename_is_move,
		input   [RA-1:0]rename_is_move_reg,
		input [NCOMMIT-1:0]commit_completed,

		output			sb_is_0,
		output			sb_is_reg,
`endif

		input [LNCOMMIT-1:0]current_end,
		input [NCOMMIT-1:0] commit_reg,
		input [NCOMMIT-1:0] commit_match,
		input				rename_reloading,
		input				rename_stall,

`ifdef RENAME_OPT
		output [RA-1:0]scoreboard_latest_commit,
`endif
		output [RA-1:0]scoreboard_latest_rename);
        parameter CNTRL_SIZE=7;
        parameter NDEC = 4; // number of decode stages
        parameter ADDR=0;
        parameter NHART=1;
        parameter LNHART=0;
		parameter HART=0;
		parameter RA=6;
		parameter RV=64;
        parameter BDEC= 4;
		parameter NCOMMIT = 32; // number of commit registers 
        parameter LNCOMMIT = 5; // number of bits to encode that


	wire	[31:1]c_stall;
	wire 	      stall=|c_stall;


	reg [RA-1:0]r_reg;
	reg [RA-1:0]c_reg;

//
//	we have 2 pointers in and out that are inclusive and a flag (not_empty)
//	for each real register (1-31) we have a vector of flags [0:NCOMMIT-1] of the commit stations
//	that say that that commit station generates that register as an output
//
//	In any clock we can:
//		a) either:
//			1) add D new entries to out (dispatch), or
//			2) delete E entries from out (miss prediction/exceptio)
//		b) remove C entries from in (commit)
//
//	So - how do we figure out the latest version of real register X? (pref without creating 31
//	barrel shifters
//
//	1) here we remember the last one put in and where it is:
//		a) when there's an exception or mispredict there's going to be a 3 clock pipe bubble
//			(fetch, decode rename) - that gives us enough time for a multi clock
//			network to figure it out
//		b) when there's a commit we simply clear it, when there's a commit for it we just clear 
//		   it's valid bit so we start referencing the real register
//	   
//
//

	reg [LNCOMMIT-1:0]na;
	reg         na_valid;
	
	wire [RA-1:0]current;
	wire [RA-1:0]na_v;

	assign scoreboard_latest_rename = r_reg;
`ifdef RENAME_OPT
	reg [RA-1:0]r_commit_reg;
	reg [RA-1:0]c_commit_reg;
	assign scoreboard_latest_commit = r_commit_reg;
`endif
					
	generate
		wire [4:0]rr = ADDR;
		wire [RA-1:0]rn_result;
		if (LNCOMMIT < 5) begin
			wire [5-LNCOMMIT-1:0]fill = 0;
			assign current = {1'b0, rr};
			assign na_v = {1'b1, fill, na};
			assign rn_result = {1'b1, fill, rename_result};
		end else
		if (LNCOMMIT == 5) begin
			assign current = {1'b0, rr};
			assign na_v = {1'b1, na};
			assign rn_result = {1'b1, rename_result};
		end else begin
			wire [LNCOMMIT-5-1:0]fill = 0;
			assign current = {1'b0, fill, rr};
			assign na_v = {1'b1, na};
			assign rn_result = {1'b1, rename_result};
		end
	
		always @(*) begin 
`ifdef RENAME_OPT
			c_commit_reg = {1'b0, {RA-1{1'bx}}};
`endif
			if (reset) begin 
				c_reg = current;
			end else
			if (!rename_reloading&rename_valid&!rename_stall) begin
`ifdef RENAME_OPT
				if (rename_is_0) begin
					c_reg = 0;	
				end else
				if (rename_is_move && (!rename_is_move_reg[RA-1] || !commit_completed[rename_is_move_reg[LNCOMMIT-1:0]])) begin
					c_reg = rename_is_move_reg;
					c_commit_reg = rn_result;
				end else begin
					c_reg = rn_result;
				end
`else
				c_reg = rn_result;
`endif
			end else
`ifdef RENAME_OPT
			if (r_reg[RA-1] && r_commit_reg[RA-1] && commit_completed[r_reg[LNCOMMIT-1:0]]) begin
				if (commit_reg[r_commit_reg[LNCOMMIT-1:0]]) begin
					c_reg = current;
				end else begin
					c_reg = r_commit_reg;
				end
			end else
`endif
			if (r_reg[RA-1] && commit_reg[r_reg[LNCOMMIT-1:0]]) begin
`ifdef RENAME_OPT
				if (r_commit_reg[RA-1] && !commit_reg[r_commit_reg[LNCOMMIT-1:0]]) begin
					c_reg = r_commit_reg;
				end else
`endif
				c_reg = current;
			end else
`ifdef RENAME_OPT
			if (r_commit_reg[RA-1] && commit_reg[r_commit_reg[LNCOMMIT-1:0]]) begin
				c_reg = current;
			end else
`endif
			if (rename_reloading) begin
				if (na_valid) begin
					c_reg = na_v;
				end else begin
					c_reg = current;
				end
			end else begin
				c_reg = r_reg;
`ifdef RENAME_OPT
				c_commit_reg = r_commit_reg;
`endif
			end
		end

`ifdef RENAME_OPT
assign sb_is_0=r_reg==0;
assign sb_is_reg= !r_reg[RA-1] && r_reg[RA-2:0] != 0 && r_reg[RA-2:0] != ADDR; 
`endif

		always @(posedge clk) 
			r_reg <= c_reg;

`ifdef RENAME_OPT
		always @(posedge clk) 
			r_commit_reg <= c_commit_reg;
`endif


		if (NCOMMIT == 16) begin
`include "mk4_16.inc"
		end else
		if (NCOMMIT == 32) begin
`include "mk4_32.inc"
		end else
		if (NCOMMIT == 64) begin
`include "mk4_64.inc"
		end 
	endgenerate
endmodule
		
module rename(
		input			clk, 
		input			reset,
		input			rv32,

		input	 [2*NDEC-1:0]valid,
		input    [ 4: 0]rs1,
		input    [ 4: 0]rs2,
		input    [ 4: 0]rs3,
		input    [ 4: 0]rd,
		input    [31: 0]immed,
		input           needs_rs2,
		input           needs_rs3,
`ifdef FP
		input			rd_fp,
		input			rs1_fp,
		input			rs2_fp,
		input			rs3_fp,
`endif
		input           makes_rd,
		input			start,
		input			short,
		input [CNTRL_SIZE-1:0]control,
		input  [UNIT_SIZE-1:0]unit_type,
		input   [VA_SZ-1:1]pc,
		input   [VA_SZ-1:1]pc_dest,
		input    [LNCOMMIT-1: 0]next_start,
		input	[RA-1: 0]renamed_rs1,
		input	[RA-1: 0]renamed_rs2,
		input	[RA-1: 0]renamed_rs3,
		input			 local1,
		input			 local2,
		input			 local3,
		input [$clog2(NUM_PENDING)-1:0]branch_token,
		input [$clog2(NUM_PENDING_RET)-1:0]branch_token_ret,
`ifdef TRACE_CACHE
		input			  branch_token_trace,
		input [$clog2(NUM_TRACE_LINES)-1:0]branch_token_trace_index,
		input[TRACE_HISTORY-1:0]branch_token_trace_history,
		input             branch_token_trace_predicted,
`endif

		input			    commit_br_enable,
		input				commit_trap_br_enable,
		input				rename_reloading,
		input				rename_stall,
		input	[NCOMMIT-1:0]commit_done,
		input				commit_int_force_fetch,
		input[LNCOMMIT-1: 0]commit_trap_br_addr,
		input       [RV-1:1]commit_trap_br,

		output	  [2*NDEC-1:0]sel_out,
		output    [4: 0]next_rd,
		output    [LNCOMMIT-1: 0]next_map_rd,
		output			   next_makes_rd,
`ifdef FP
		output			   next_rd_fp,
`endif
		output    [RA-1: 0]rs1_out,
		output    [RA-1: 0]rs2_out,
		output    [RA-1: 0]rs3_out,
		output    [ 4: 0]real_rs1_out,
		output    [ 4: 0]real_rs2_out,
		output    [ 4: 0]real_rs3_out,
		output    [LNCOMMIT-1: 0]rd_out,
		output    [  4: 0]rd_real_out,
		output    [31: 0]immed_out,
		output           needs_rs2_out,
		output           needs_rs3_out,
		output           makes_rd_out,
`ifdef FP
		output			 rd_fp_out,
		output			 rs1_fp_out,
		output			 rs2_fp_out,
		output			 rs3_fp_out,
`endif
		output			 start_out,
		output			 short_out,
		output [CNTRL_SIZE-1:0]control_out,
		output  [UNIT_SIZE-1:0]unit_type_out,
		output   [VA_SZ-1:1]pc_out,
		output   [VA_SZ-1:1]pc_dest_out,
		output			will_be_valid,
		output [$clog2(NUM_PENDING)-1:0]branch_token_out,
		output [$clog2(NUM_PENDING_RET)-1:0]branch_token_ret_out,
`ifdef TRACE_CACHE
		output			branch_token_trace_out,
		output		[$clog2(NUM_TRACE_LINES)-1:0]branch_token_trace_index_out,
		output		[TRACE_HISTORY-1:0]branch_token_trace_history_out,
		output		    branch_token_trace_predicted_out,
`endif
		output			valid_out
`ifdef INSTRUCTION_FUSION
		,
		input  [31:0]immed2,
		input [4:0]orig_rs1,
		input [4:0]orig_rs2,
		input       orig_makes_rd,
		input		orig_needs_rs2,
		output    [31: 0]immed2_out,
		output	renamed_is_complex_return,
		output	renamed_is_add_const,
		output	renamed_is_add_r0,
		output	renamed_is_add_r0_rs2,
		output	renamed_is_load_immediate,
		output	renamed_is_const_branch,
		output	renamed_is_add_to_prev, 
		output	renamed_is_add_to_auipc, 
		output  renamed_is_simple_ld_st,
		input	next_is_complex_return,
		input	next_is_const_branch,
		input	next_is_add_to_prev,
		input	prev_is_add_to_auipc,
		input	prev_is_add_const,
		input	prev_is_load_immediate,
		input	prev_is_add_r0,
		input  [4:0]prev_rd,
		input  [4:0]prev_rs1,
		input  [4:0]prev_rs2,
		input  [31:0]prev_immed,
		input  [RV-1:1]prev_pc
`endif
`ifdef RENAME_OPT
		,
		input	[NCOMMIT-1:0]commit_completed,
		output			next_is_0,
		output			next_is_move,
		output     [4:0]next_is_move_reg,
	    input    [RA-1:0]renamed_commit_rs1,
	    input    [RA-1:0]renamed_commit_rs2,
	    input    [RA-1:0]renamed_commit_rs3,
	    output    [RA-1:0]renamed_commit_rs1_out,
	    output    [RA-1:0]renamed_commit_rs2_out,
	    output    [RA-1:0]renamed_commit_rs3_out
`endif
		);

	parameter CNTRL_SIZE=7;
	parameter UNIT_SIZE=4;
	parameter NDEC = 4; // number of decode stages
	parameter ADDR=0;
	parameter HART=0;
	parameter NHART=1;
	parameter LNHART=0;
	parameter BDEC = 4;
	parameter RA=5;
	parameter RV=64;
	parameter VA_SZ=48;
	parameter NCOMMIT=5;
	parameter LNCOMMIT=5;
	parameter NUM_PENDING=32;
	parameter NUM_PENDING_RET=8;
	parameter NUM_TRACE_LINES=64;
	parameter TRACE_HISTORY=5;

`ifdef INSTRUCTION_FUSION

	wire [31:0]immed_add;
	wire		is_simple_const;
	generate

		if (ADDR==0) begin
			assign is_simple_const = 0;
			assign immed_add = 'bx;
		end else begin
			assign is_simple_const = prev_immed[11:0] == 0 && (!|immed[31:12]  || &immed[31:12]);
			// there are 7 of these adders, but note there's only 1 bit in the 2nd term 
			//		there's a lot of scope for optimisation
			assign immed_add = {prev_immed[31:12], immed[11:0]}-{19'b0, immed[12], 12'b0};
		end
	
	endgenerate
	//
	//	we're limited by register read ports per ALU, we're going to rewrite
	//	the following into one instruction:
	//
	//	1)	add   a, b, #C	is_add_const  (DELETED)
	//		ret				is_complex_return
	//
	//	2)  add	  a, r0, #C	is_add_const  (DELETED)
	//		bxx	  a, d, br	is_const_branch is_const_branch_rs1
	//
	//	3)  add	  a, r0, #C	is_add_const  (DELETED)
	//		bxx	  d, a, br	is_const_branch !is_const_branch_rs1
	//
	//	4)  lui	  a, hi(X)		is_simple_const && is_add_const && prev_rs1 == 0
	//		ld/st	b, lo(X)(a)	is_simple_ld_st note: in this case we don't kill the first inst we
	//								map to "lui a, hi(X); ld/st   b, X(r0)" this lets the load run
	//								one clock early
	//	5)  lui	a, hi(X)		 is_simple_const && is_add_const && prev_rs1 == 0  (DELETED)
	//		add  a, a, lo(X)	 is_add_to_prev   -> li   a, X
	//
	//	6)  auipc	a, hi(X)	 is_add_to_auipc && is_add_const && prev_rs1 == 0  (DELETED)
	//		add  a, a, lo(X)	 is_add_to_auipc   -> auipc   a, X
	//
	reg	is_simple_ld_st, is_add_to_prev, is_add_to_auipc;
	reg	is_load_immediate, is_add_const, is_const_branch, is_const_branch_rs1, is_complex_return;
	reg is_add_r0, is_add_r0_rs2;
	assign	renamed_is_complex_return = is_complex_return;
	assign	renamed_is_add_const = is_add_const;
	assign	renamed_is_load_immediate = is_load_immediate;
	assign	renamed_is_const_branch = is_const_branch;
	assign	renamed_is_add_r0 = is_add_r0;
	assign	renamed_is_add_r0_rs2 = is_add_r0_rs2;
	assign	renamed_is_add_to_prev = is_add_to_prev;
	assign	renamed_is_add_to_auipc = is_add_to_auipc;
	assign	renamed_is_simple_ld_st = is_simple_ld_st;
	assign	renamed_is_add_to_auipc = is_add_to_auipc;
	always @(*) begin
		is_add_const = 0;
		is_const_branch = 0;
		is_const_branch_rs1 = 'bx;
		is_complex_return = 0;
		is_load_immediate = 0;
		is_simple_ld_st = 0;
		is_add_to_prev = 0;
		is_add_r0 = 0;
		is_add_r0_rs2 = 0;
		is_add_to_auipc = 0;
		case (unit_type) // synthesis full_case parallel_case
		0:	begin
				case (control[5:0])
				6'b000_000: 
					if (orig_makes_rd)
					if (!orig_needs_rs2) begin
						is_add_const = 1;
						is_load_immediate = orig_rs1 == 0;
						is_add_to_prev = rd == orig_rs1 && orig_rs1 == prev_rd && prev_rs2 == 0 && is_simple_const && (prev_is_add_const|prev_is_add_to_auipc);
					end else begin
						is_add_r0 = orig_rs1 == 0 || orig_rs2 == 0;
						is_add_r0_rs2 = orig_rs2 == 0;
					end
				6'b010_000:		// addwi
					if (orig_makes_rd)
					if (!orig_needs_rs2) begin
						is_add_to_prev = rd == orig_rs1 && orig_rs1 == prev_rd && prev_rs2 == 0 && is_simple_const && (prev_is_add_const|prev_is_add_to_auipc);
					end
				6'b100_000: 
					if (orig_makes_rd)
					if (!orig_needs_rs2) begin
`ifdef TRACE_CACHE
						is_add_to_auipc = 0;	// disable until we can figure out how to handle this with
												// the trace cache
`else
						is_add_to_auipc = 1;	
`endif
					end
				default:;
				endcase
			end
		3:  begin
				if (control[4] == 0) 
					is_simple_ld_st = is_simple_const && prev_is_add_const && prev_rs1 == 0 && orig_rs1 == prev_rd;
			end
		4:  begin
				if (control[5:4] == 0) 
					is_simple_ld_st = is_simple_const && prev_is_add_const && prev_rs1 == 0 && orig_rs1 == prev_rd;
			end
		6:	begin
				case ({orig_makes_rd, control[0]}) 
				2'b01:	if (prev_is_load_immediate &&
								((prev_rd == orig_rs1 && prev_rd != orig_rs2) ||
								 (prev_rd == orig_rs2 && prev_rd != orig_rs1))) begin
							is_const_branch = 1;
							is_const_branch_rs1 = prev_rd == orig_rs1;
						end
				2'b00:  if ((prev_is_add_const || prev_is_add_r0)  && prev_rd != orig_rs1) begin
							is_complex_return = 1;
						end
				default:;
				endcase
			end
		endcase
	end
`endif

`ifdef RENAME_OPT
	reg is_0;
	reg is_move;
	reg [4:0]is_move_reg;
	assign next_is_0 = is_0;
	assign next_is_move = is_move;
	assign next_is_move_reg = is_move_reg;
	always @(*) begin
		is_0 = 0;
		is_move = 0;
		is_move_reg = 'bx;
		case (unit_type) // synthesis full_case parallel_case
		0:	begin
				case ({control[5], control[2:0]}) // synthesis full_case parallel_case
				0_000: if (!control[4]) // add
					   if (control[3]) begin
							is_0 = rs1 == rs2 && needs_rs2;
					   end else begin
							is_0 = (rs1==0) && (needs_rs2 ? rs2==0:immed==0);
							is_move = (rs1 == 0 && needs_rs2) ||
							          (needs_rs2 ? rs2==0 : immed==0 );
							is_move_reg = (rs1 == 0 && needs_rs2 ? rs2 : rs1);
					   end
				0_001: if (!control[4])	// xor
					   if (!control[3]) begin
							is_0 = (rs1 == rs2) && needs_rs2;
							is_move = (rs1 == 0 && needs_rs2) ||
							          (needs_rs2 ? rs2==0: immed==0);
							is_move_reg = (rs1 == 0 && needs_rs2 ? rs2 : rs1);
					   end
				0_010: if (!control[4])	// and
					   if (!control[3]) begin
							is_0 = rs1 == 0 || (needs_rs2 ? rs2==0 : immed==0);
							is_move = (rs1 == rs2) && needs_rs2;
							is_move_reg = (rs1 == 0 && needs_rs2 ? rs2 : rs1);
					   end
				0_011: if (!control[4])	// or
					   if (!control[3]) begin
							is_0 = rs1 == 0 && (needs_rs2 ? rs2==0 : immed==0);
							is_move = (rs1 == 0 && needs_rs2) ||
							          (needs_rs2? rs2 == 0 : immed == 0);
							is_move_reg = (rs1 == 0 && needs_rs2 ? rs2 : rs1);
					   end
				default:;
				endcase
			end
		default:;
		endcase
	end
`endif


	reg    [   4: 0]r_real_rs1_out;
	reg    [   4: 0]r_real_rs2_out;
	reg    [   4: 0]r_real_rs3_out;
	assign real_rs1_out = r_real_rs1_out;
	assign real_rs2_out = r_real_rs2_out;
	assign real_rs3_out = r_real_rs3_out;
`ifdef RENAME_OPT
	reg    [RA-1: 0]r_renamed_commit_rs1_out;
	reg    [RA-1: 0]r_renamed_commit_rs2_out;
	reg    [RA-1: 0]r_renamed_commit_rs3_out;
	assign  renamed_commit_rs1_out = r_renamed_commit_rs1_out;
	assign  renamed_commit_rs2_out = r_renamed_commit_rs2_out;
	assign  renamed_commit_rs3_out = r_renamed_commit_rs3_out;
`endif
	reg    [RA-1: 0]r_rs1_out;
	reg    [RA-1: 0]r_rs2_out;
	reg    [RA-1: 0]r_rs3_out;
	reg    [LNCOMMIT-1: 0]r_rd_out;
	reg    [ 4: 0]r_rd_real_out;
	reg    [31: 0]r_immed_out;
`ifdef INSTRUCTION_FUSION
	reg    [31: 0]r_immed2_out;
`endif
	reg [$clog2(NUM_PENDING)-1:0]r_branch_token_out;
	reg [$clog2(NUM_PENDING_RET)-1:0]r_branch_token_ret_out;
`ifdef TRACE_CACHE
	reg			  r_branch_token_trace_out;
	reg	[$clog2(NUM_TRACE_LINES)-1:0]r_branch_token_trace_index_out;
	reg	[TRACE_HISTORY-1:0]r_branch_token_trace_history_out;
	reg			  r_branch_token_trace_predicted_out;
`endif
	reg           r_needs_rs2_out;
	reg           r_needs_rs3_out;
	reg           r_makes_rd_out;
	reg           r_start_out;
	reg           r_short_out;
`ifdef FP
	reg			  r_rd_fp_out;
	reg			  r_rs1_fp_out;
	reg			  r_rs2_fp_out;
	reg			  r_rs3_fp_out;
`endif
	reg [CNTRL_SIZE-1:0]r_control_out;
	reg  [UNIT_SIZE-1:0]r_unit_type_out;
	reg   [VA_SZ-1:1]r_pc_out;
	reg   [VA_SZ-1:1]r_pc_dest_out;
	reg		r_valid_out;
	assign  rs1_out = r_rs1_out;
	assign  rs2_out = r_rs2_out;
	assign  rs3_out = r_rs3_out;
	assign  rd_out = r_rd_out;
	assign  immed_out = r_immed_out;
`ifdef INSTRUCTION_FUSION
	assign  immed2_out = r_immed2_out;
`endif
	assign  needs_rs2_out = r_needs_rs2_out;
	assign  needs_rs3_out = r_needs_rs3_out;
`ifdef FP
	assign	rd_fp_out = r_rd_fp_out;
	assign	rs1_fp_out = r_rs1_fp_out;
	assign	rs2_fp_out = r_rs2_fp_out;
	assign	rs3_fp_out = r_rs3_fp_out;
`endif
	assign  makes_rd_out = r_makes_rd_out;
	assign  start_out = r_start_out;
	assign  short_out = r_short_out;
	assign  control_out = r_control_out;
	assign  unit_type_out = r_unit_type_out;
	assign  pc_out = r_pc_out;
	assign  pc_dest_out = r_pc_dest_out;
	assign	valid_out = r_valid_out&!(rename_stall|rename_reloading);
	assign rd_real_out = r_rd_real_out;

	assign next_map_rd = next_start+ADDR;
	assign next_rd = rd;
`ifdef INSTRUCTION_FUSION
	assign next_makes_rd = makes_rd&c_valid_out&!(next_is_const_branch|next_is_complex_return|next_is_add_to_prev);
`else
	assign next_makes_rd = makes_rd&c_valid_out;
`endif
`ifdef FP
	assign next_rd_fp = rd_fp;
	//assign next_rd_fp = rd_fp&c_valid_out;
`endif
	assign branch_token_out =  r_branch_token_out;
	assign branch_token_ret_out = r_branch_token_ret_out;
`ifdef TRACE_CACHE
	assign branch_token_trace_out = r_branch_token_trace_out;
	assign branch_token_trace_index_out = r_branch_token_trace_index_out;
	assign branch_token_trace_history_out = r_branch_token_trace_history_out;
	assign branch_token_trace_predicted_out = r_branch_token_trace_predicted_out;
`endif
	
	reg [2*NDEC-1:0]sel;	// 1-hot
	assign sel_out = sel;
	reg      c_valid_out;

	generate
		if (NDEC==2) begin
`include "mkinc4.inc"
		end else 
		if (NDEC==4) begin
`include "mkinc8.inc"
		end else 
		if (NDEC==8) begin
`include "mkinc16.inc"
		end else begin
			// sel = 1'bx;
			// c_valid_out = 1bx;
		end
	endgenerate

	
	//
	//	the above is essentially:
	//	always @(*) begin : nth
	//		integer i, count;
	//		count = 0;
	//		c_valid_out = 0;
	//		sel = 6'bxxxxxx;
	//		for (i = 0; i < 2*NDEC && !c_valid_out ; i=i+1) 
	//		if (valid[i]) begin
	//			if (count == ADDR) begin
	//				c_valid_out = 1;
	//				sel = 1<<i;
	//			end else begin
	//				count = count+1;
	//			end
	//		end
	//	end
	//	wire [4:0]d = rd[sel];
	//	wire [4:0]s1 = rs1[sel];
	//	wire [4:0]s2 = rs2[sel];
	//	wire [4:0]s3 = rs3[sel];
	

	assign will_be_valid = c_valid_out;
	reg r_local1,r_local2,r_local3;

	always @(posedge clk)
	if (commit_int_force_fetch && ADDR <= 1) begin	// vector fetch
		if (ADDR == 0) begin
			r_local1 <= 1;		// ld tmp, (tmp)
			r_local2 <= 1;
			r_local3 <= 1;
			r_real_rs1_out <= 0;
			r_real_rs2_out <= 0;
			r_real_rs3_out <= 0;
`ifdef RENAME_OPT
			r_renamed_commit_rs1_out <= {1'b0, {RA-1{'bx}}};
			r_renamed_commit_rs2_out <= {1'b0, {RA-1{'bx}}};
			r_renamed_commit_rs3_out <= {1'b0, {RA-1{'bx}}};
`endif
			r_rs1_out <= {1'b1, commit_trap_br_addr};
			r_rs2_out <= 0;
			r_rs3_out <= 0;
			r_rd_out <= commit_trap_br_addr+1;
			r_rd_real_out <= 0;
			r_immed_out <= 0;
`ifdef INSTRUCTION_FUSION
			r_immed2_out <= 0;
`endif
			r_needs_rs2_out <= 0;
			r_needs_rs3_out <= 0;
			r_makes_rd_out <= 1;
			r_short_out <= 0;
			r_start_out <= 0;
`ifdef FP
			r_rd_fp_out <= 0;
			r_rs1_fp_out <= 0;
			r_rs2_fp_out <= 0;
			r_rs3_fp_out <= 0;
`endif
			r_control_out <= (rv32?{1'bx, 1'b0, 1'b0, 1'b0, 2'b10} :{1'bx, 1'b0, 1'b0, 1'b0, 2'b11});
			r_unit_type_out <= 3;
			r_pc_out <= commit_trap_br[VA_SZ-1:1];
			r_valid_out <= 1;
			r_branch_token_out <= 0;
			r_branch_token_ret_out <= 0;
`ifdef TRACE_CACHE
			r_branch_token_trace_out <= 0;
			r_branch_token_trace_index_out <= 'bx;
			r_branch_token_trace_history_out <= 'bx;
			r_branch_token_trace_predicted_out <= 'bx;
`endif
		end else begin
			r_local1 <= 1;		// int  #1, tmp
			r_local2 <= 1;
			r_local3 <= 1;
			r_real_rs1_out <= 0;
			r_real_rs2_out <= 0;
			r_real_rs3_out <= 0;
`ifdef RENAME_OPT
			r_renamed_commit_rs1_out <= {1'b0, {RA-1{'bx}}};
			r_renamed_commit_rs2_out <= {1'b0, {RA-1{'bx}}};
			r_renamed_commit_rs3_out <= {1'b0, {RA-1{'bx}}};
`endif
`ifdef FP
			r_rd_fp_out <= 0;
			r_rs1_fp_out <= 0;
			r_rs2_fp_out <= 0;
			r_rs3_fp_out <= 0;
`endif
			r_rs1_out <= {1'b1, commit_trap_br_addr+1'b1};
			r_rs2_out <= 0;
			r_rs3_out <= 0;
			r_rd_out <= commit_trap_br_addr+2;
			r_rd_real_out <= 0;
			r_immed_out <= 0;
`ifdef INSTRUCTION_FUSION
			r_immed2_out <= 0;
`endif
			r_needs_rs2_out <= 0;
			r_needs_rs3_out <= 0;
			r_makes_rd_out <= 0;
			r_short_out <= 0;
			r_start_out <= 0;
			r_control_out <= {2'b01, 4'd1};
			r_unit_type_out <= 7;
			r_pc_out <= commit_trap_br[VA_SZ-1:1];
			r_valid_out <= 1;
			r_branch_token_out <= 0;
			r_branch_token_ret_out <= 0;
`ifdef TRACE_CACHE
			r_branch_token_trace_out <= 0;
			r_branch_token_trace_index_out <= 'bx;
			r_branch_token_trace_history_out <= 'bx;
			r_branch_token_trace_predicted_out <= 'bx;
`endif
		end
	end else
	if (!rename_stall|commit_br_enable|commit_trap_br_enable) begin
		r_local1 <= local1;
		r_local2 <= local2;
		r_local3 <= local3;
`ifdef INSTRUCTION_FUSION
		if (next_is_complex_return|next_is_const_branch|next_is_add_to_prev) begin
			r_real_rs1_out <= 0;
			r_real_rs2_out <= 0;
			r_real_rs3_out <= 0;
			r_rs1_out <= 0;
			r_rs2_out <= 0;
			r_rs3_out <= 0;
		end else begin
			r_real_rs1_out <= is_const_branch&is_const_branch_rs1?0:rs1;
			r_real_rs2_out <= is_const_branch&!is_const_branch_rs1?0:rs2;
			r_real_rs3_out <= rs3;
			r_rs1_out <= is_const_branch&is_const_branch_rs1?0:((renamed_rs1[RA-1] && commit_done[renamed_rs1[LNCOMMIT-1:0]])?rs1:renamed_rs1);
			r_rs2_out <= is_const_branch&!is_const_branch_rs1?0:((renamed_rs2[RA-1] && commit_done[renamed_rs2[LNCOMMIT-1:0]])?rs2:renamed_rs2);
			r_rs3_out <= ((renamed_rs3[RA-1] && commit_done[renamed_rs3[LNCOMMIT-1:0]])?rs3:renamed_rs3);
		end
`else
		r_real_rs1_out <= rs1;
		r_real_rs2_out <= rs2;
		r_real_rs3_out <= rs3;
		r_rs1_out <= ((renamed_rs1[RA-1] && commit_done[renamed_rs1[LNCOMMIT-1:0]])?rs1:renamed_rs1);
		r_rs2_out <= ((renamed_rs2[RA-1] && commit_done[renamed_rs2[LNCOMMIT-1:0]])?rs2:renamed_rs2);
		r_rs3_out <= ((renamed_rs3[RA-1] && commit_done[renamed_rs3[LNCOMMIT-1:0]])?rs3:renamed_rs3);
`endif
`ifdef RENAME_OPT
		r_renamed_commit_rs1_out <= (!renamed_commit_rs1[RA-1] || commit_completed[renamed_commit_rs1[LNCOMMIT-1:0]])?{1'b0, {RA-1{'bx}}}:renamed_commit_rs1;
		r_renamed_commit_rs2_out <= (!renamed_commit_rs2[RA-1] || commit_completed[renamed_commit_rs2[LNCOMMIT-1:0]])?{1'b0, {RA-1{'bx}}}:renamed_commit_rs2;
		r_renamed_commit_rs3_out <= (!renamed_commit_rs3[RA-1] || commit_completed[renamed_commit_rs3[LNCOMMIT-1:0]])?{1'b0, {RA-1{'bx}}}:renamed_commit_rs3;
`endif
		r_rd_out <= next_map_rd;
		r_rd_real_out <= rd;
		r_needs_rs3_out <= needs_rs3;
`ifdef INSTRUCTION_FUSION
		r_immed2_out <= is_complex_return&prev_is_add_r0 ? 32'b0 : is_complex_return | is_const_branch? prev_immed: immed2;
		r_needs_rs2_out <= needs_rs2 | is_complex_return | is_const_branch;
		r_makes_rd_out <= (makes_rd | is_complex_return | is_const_branch) & !(next_is_complex_return|next_is_const_branch|next_is_add_to_prev);
		casez ({is_complex_return, is_const_branch, is_add_to_prev&prev_is_add_to_auipc}) // synthesis full_)case parallel_case
		3'b1??,
		3'b?1?: r_control_out <= {1'b1, is_const_branch_rs1, control[5:0]};
		3'b??1: r_control_out <= {control[7:6], 1'b1,  control[4:0]};
		3'b000: r_control_out <= control;
		endcase
		r_immed_out <= (is_add_to_prev|is_simple_ld_st?immed_add:immed);
		if (is_add_to_prev&prev_is_add_to_auipc) begin
			r_pc_out <= prev_pc;
		end else begin
			r_pc_out <= pc;
		end
`else
		r_needs_rs2_out <= needs_rs2;
		r_makes_rd_out <= makes_rd;
		r_control_out <= control;
		r_immed_out <= immed;
		r_pc_out <= pc;
`endif
		r_short_out <= short;
		r_start_out <= start;
`ifdef FP
		r_rd_fp_out <= rd_fp;
		r_rs1_fp_out <= rs1_fp;
		r_rs2_fp_out <= rs2_fp;
		r_rs3_fp_out <= rs3_fp;
`endif
		r_unit_type_out <= unit_type;
		r_pc_dest_out <= pc_dest;
		r_valid_out <= c_valid_out&!(commit_br_enable|commit_trap_br_enable|rename_reloading);
		r_branch_token_out <= branch_token;
		r_branch_token_ret_out <= branch_token_ret;
`ifdef TRACE_CACHE
		r_branch_token_trace_out <= branch_token_trace;
		r_branch_token_trace_index_out <= branch_token_trace_index;
		r_branch_token_trace_history_out <= branch_token_trace_history;
		r_branch_token_trace_predicted_out <= branch_token_trace_predicted;
`endif
	end else begin
		if (!r_local1 && r_rs1_out[RA-1] && commit_done[r_rs1_out[LNCOMMIT-1:0]])
			r_rs1_out <= r_real_rs1_out;
		if (!r_local2 && r_rs2_out[RA-1] && commit_done[r_rs2_out[LNCOMMIT-1:0]])
			r_rs2_out <= r_real_rs2_out;
		if (!r_local3 && r_rs3_out[RA-1] && commit_done[r_rs3_out[LNCOMMIT-1:0]])
			r_rs3_out <= r_real_rs3_out;
`ifdef RENAME_OPT
		if (r_renamed_commit_rs1_out[RA-1] && commit_completed[r_renamed_commit_rs1_out[LNCOMMIT-1:0]])
			r_renamed_commit_rs1_out <= {1'b0, {RA-1{'bx}}};
		if (r_renamed_commit_rs2_out[RA-1] && commit_completed[r_renamed_commit_rs2_out[LNCOMMIT-1:0]])
			r_renamed_commit_rs2_out <= {1'b0, {RA-1{'bx}}};
		if (r_renamed_commit_rs3_out[RA-1] && commit_completed[r_renamed_commit_rs3_out[LNCOMMIT-1:0]])
			r_renamed_commit_rs3_out <= {1'b0, {RA-1{'bx}}};
`endif
	end

`ifdef AWS_DEBUG
`ifdef NOTDEF
	ila_rename ila_rn(.clk(clk),
		.reset(reset),
		.valid(valid_out),
		.pc({pc_out[31:1],1'b0}),
		.unit_type(unit_type_out),
		.rs1(rs1_out),
		.rs2(rs2_out));
`endif
`endif
endmodule

/* For Emacs:
 * Local Variables:
 * mode:c
 * indent-tabs-mode:t
 * tab-width:4
 * c-basic-offset:4
 * End:
 * For VIM:
 * vim:set softtabstop=4 shiftwidth=4 tabstop=4:
 */
