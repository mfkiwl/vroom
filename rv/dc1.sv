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

`include "lstypes.si"

module dcache_l1(
    input clk,
//`ifdef VSYNTH
//    input      clkX4,   // 4x clock for sync dual port ram
//    input [3:0]clkX4_phase, // clkX4_phase[0] samples true on rising edge of clk
//`endif
    input reset,
`ifdef SIMD
	input simd_enable,
`endif
`ifdef AWS_DEBUG
	input xxtrig,
	output dc_trig,
`endif


	DCACHE_LOAD load,

	input         wenable0,				// CPU write port
	input [NPHYS-1:$clog2(RV/8)]waddr0,
	input [RV-1:0]wdata0,
	input [(RV/8)-1:0]wmask0,
	output		  whit_ok_write0,
	output		  whit_must_invalidate0,
	output		  wwait0,

	input [NPHYS-1:ACACHE_LINE_SIZE]dc_snoop_addr,			// snoop port
	input 	    dc_snoop_addr_req,
	input 	    dc_snoop_addr_ack,
	input  [1:0]dc_snoop_snoop,

	output [2:0]dc_snoop_data_resp,
	output[CACHE_LINE_SIZE-1:0]dc_snoop_data,

	input		dc_rdata_req,
	output		dc_rdata_ack,
	input [CACHE_LINE_SIZE-1:0]dc_rdata,
	input [NPHYS-1:ACACHE_LINE_SIZE]dc_raddr,
	input [2:0]dc_rdata_resp,

	output[NPHYS-1:ACACHE_LINE_SIZE]dc_waddr,
    output      dc_waddr_req,
    input       dc_waddr_ack,
    output [1:0]dc_waddr_snoop,
    output [TRANS_ID_SIZE-1:0]dc_waddr_trans,
    output[CACHE_LINE_SIZE-1:0]dc_wdata,

	input	irand,
	output	orand,
	
	input dummy);

`include "cache_protocol.si"



	parameter RV=64;
	parameter ACACHE_LINE_SIZE=6;
	parameter CACHE_LINE_SIZE=64*8;		// 64 bytes   5:0	- 6 bits	32 bytes
	parameter NENTRIES=64;				// index      11:6	- 6 bits	4kbytes
`ifdef PSYNTH
	parameter NSETS=16;					//					32k - aws xylinx suffers dc congestion
`else
	parameter NSETS=32;					//					64k
`endif
	parameter NPHYS=56;
	parameter READPORTS=2;
	parameter WRITEPORTS=1;
	parameter LFWRITEPORTS=1;
	parameter NLDSTQ=8;
	parameter TRANS_ID_SIZE=6;

	reg    [2:0]r_moesi[0:NSETS-1][0:NENTRIES-1];
	wire   [NPHYS-1:12]fetch_wtags[0:NSETS-1];

	wire [CACHE_LINE_SIZE-1:0]rd[0:READPORTS-1][0:NSETS-1];
	reg [CACHE_LINE_SIZE-1:0]rdd[0:READPORTS-1];

	wire		wenable[0:WRITEPORTS-1];
	assign wenable[0]=wenable0;
	wire [NPHYS-1:$clog2(RV/8)]waddr[0:WRITEPORTS-1];
	assign waddr[0]=waddr0;
	wire [RV-1:0]wdata[0:WRITEPORTS-1];
	assign wdata[0]=wdata0;
	reg [CACHE_LINE_SIZE-1:0]ww[0:WRITEPORTS-1];
	wire [(RV/8)-1:0]wmask[0:WRITEPORTS-1];
	assign wmask[0]=wmask0;
	wire           whit_ok_write[0:WRITEPORTS-1];
	assign whit_ok_write0 = whit_ok_write[0];
	wire           whit_must_invalidate[0:WRITEPORTS-1];
	assign whit_must_invalidate0 = whit_must_invalidate[0];

	wire           wwait[0:WRITEPORTS-1];
	assign wwait0 = wwait[0];

	reg		c_dc_rdata_ack;
	assign dc_rdata_ack = c_dc_rdata_ack;
	reg [CACHE_LINE_SIZE-1:0]r_dc_wdata, c_dc_wdata;
	assign dc_wdata = r_dc_wdata;
	reg[NPHYS-1:ACACHE_LINE_SIZE]r_dc_waddr, c_dc_waddr;
	assign dc_waddr = r_dc_waddr;
	reg			r_dc_waddr_req, c_dc_waddr_req;
	assign		dc_waddr_req = r_dc_waddr_req;
    reg  [TRANS_ID_SIZE-1:0]r_dc_waddr_trans, c_dc_waddr_trans;
	assign dc_waddr_trans = r_dc_waddr_trans;
    reg	 [1:0]r_dc_waddr_snoop, c_dc_waddr_snoop;
	assign dc_waddr_snoop = r_dc_waddr_snoop;


	reg     [2:0]r_dc_snoop_data_resp, c_dc_snoop_data_resp;
	assign		dc_snoop_data_resp = r_dc_snoop_data_resp;
	reg   [CACHE_LINE_SIZE-1:0]r_dc_snoop_data, c_dc_snoop_data;
	wire   [CACHE_LINE_SIZE-1:0]fetch_snoop_data[0:NSETS-1];
	wire   [CACHE_LINE_SIZE-1:0]fetch_wdata[0:NSETS-1];
	assign		dc_snoop_data = r_dc_snoop_data;

	always @(posedge clk) begin
		r_dc_snoop_data_resp <= c_dc_snoop_data_resp;
		r_dc_snoop_data <= c_dc_snoop_data;
	end
		
	reg [NSETS-1:0]s;

	reg [NSETS-1:0]wl;
	reg [NSETS-1:0]wm;
	wire [NSETS-1:0]match_ok_write[0:WRITEPORTS-1];		// we can write to this in this clock
	wire [NSETS-1:0]writing_set[0:WRITEPORTS-1];		// we WILL write to this set in this clock

	genvar S, R, W, B, M;
	generate begin :g
		wire [NSETS-1:0]match_snoop;
		wire [NSETS-1:0]match_dirty;
		wire [NSETS-1:0]match_exclusive;
		wire [NSETS-1:0]match_owned;
		wire [2:0]current_moesi[0:NSETS-1];
		reg [2:0]new_moesi[0:NSETS-1];
		

		if (NSETS == 16) begin
			always @(*) begin
				if (dc_snoop_addr_req&dc_snoop_addr_ack) begin
					if (!(|match_snoop)) begin
						c_dc_snoop_data = 512'bx;
						c_dc_snoop_data_resp = 0;
					end else begin
						c_dc_snoop_data_resp = {|(match_snoop&match_dirty) && dc_snoop_snoop==SNOOP_READ_EXCLUSIVE, |(match_snoop&match_exclusive) && dc_snoop_snoop==SNOOP_READ_EXCLUSIVE, dc_snoop_snoop!=SNOOP_READ_INVALID&&(|match_snoop)};
						if (dc_snoop_snoop == SNOOP_READ_INVALID) begin
							c_dc_snoop_data = 512'bx;
						end else
						casez (match_snoop) // synthesis full_case parallel_case
						16'b1???_????_????_????:	c_dc_snoop_data = fetch_snoop_data[15];
						16'b?1??_????_????_????:	c_dc_snoop_data = fetch_snoop_data[14];
						16'b??1?_????_????_????:	c_dc_snoop_data = fetch_snoop_data[13];
						16'b???1_????_????_????:	c_dc_snoop_data = fetch_snoop_data[12];
						16'b????_1???_????_????:	c_dc_snoop_data = fetch_snoop_data[11];
						16'b????_?1??_????_????:	c_dc_snoop_data = fetch_snoop_data[10];
						16'b????_??1?_????_????:	c_dc_snoop_data = fetch_snoop_data[9];
						16'b????_???1_????_????:	c_dc_snoop_data = fetch_snoop_data[8];
						16'b????_????_1???_????:	c_dc_snoop_data = fetch_snoop_data[7];
						16'b????_????_?1??_????:	c_dc_snoop_data = fetch_snoop_data[6];
						16'b????_????_??1?_????:	c_dc_snoop_data = fetch_snoop_data[5];
						16'b????_????_???1_????:	c_dc_snoop_data = fetch_snoop_data[4];
						16'b????_????_????_1???:	c_dc_snoop_data = fetch_snoop_data[3];
						16'b????_????_????_?1??:	c_dc_snoop_data = fetch_snoop_data[2];
						16'b????_????_????_??1?:	c_dc_snoop_data = fetch_snoop_data[1];
						16'b????_????_????_???1:	c_dc_snoop_data = fetch_snoop_data[0];
						endcase
					end
				end else begin
					c_dc_snoop_data_resp = r_dc_snoop_data_resp;
					c_dc_snoop_data = r_dc_snoop_data;
				end
			end
		end else begin
			always @(*) begin
				if (dc_snoop_addr_req&dc_snoop_addr_ack) begin
					if (!(|match_snoop)) begin
						c_dc_snoop_data = 512'bx;
						c_dc_snoop_data_resp = 0;
					end else begin
						c_dc_snoop_data_resp = {|(match_snoop&match_dirty) && dc_snoop_snoop==SNOOP_READ_EXCLUSIVE, |(match_snoop&match_exclusive) && dc_snoop_snoop==SNOOP_READ_EXCLUSIVE, dc_snoop_snoop!=SNOOP_READ_INVALID&&(|match_snoop)};
						if (dc_snoop_snoop == SNOOP_READ_INVALID) begin
							c_dc_snoop_data = 512'bx;
						end else
						casez (match_snoop) // synthesis full_case parallel_case
						32'b1???_????_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[31];
						32'b?1??_????_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[30];
						32'b??1?_????_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[29];
						32'b???1_????_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[28];
						32'b????_1???_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[27];
						32'b????_?1??_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[26];
						32'b????_??1?_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[25];
						32'b????_???1_????_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[24];
						32'b????_????_1???_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[23];
						32'b????_????_?1??_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[22];
						32'b????_????_??1?_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[21];
						32'b????_????_???1_????_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[20];
						32'b????_????_????_1???_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[19];
						32'b????_????_????_?1??_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[18];
						32'b????_????_????_??1?_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[17];
						32'b????_????_????_???1_????_????_????_????:	c_dc_snoop_data = fetch_snoop_data[16];
						32'b????_????_????_????_1???_????_????_????:	c_dc_snoop_data = fetch_snoop_data[15];
						32'b????_????_????_????_?1??_????_????_????:	c_dc_snoop_data = fetch_snoop_data[14];
						32'b????_????_????_????_??1?_????_????_????:	c_dc_snoop_data = fetch_snoop_data[13];
						32'b????_????_????_????_???1_????_????_????:	c_dc_snoop_data = fetch_snoop_data[12];
						32'b????_????_????_????_????_1???_????_????:	c_dc_snoop_data = fetch_snoop_data[11];
						32'b????_????_????_????_????_?1??_????_????:	c_dc_snoop_data = fetch_snoop_data[10];
						32'b????_????_????_????_????_??1?_????_????:	c_dc_snoop_data = fetch_snoop_data[9];
						32'b????_????_????_????_????_???1_????_????:	c_dc_snoop_data = fetch_snoop_data[8];
						32'b????_????_????_????_????_????_1???_????:	c_dc_snoop_data = fetch_snoop_data[7];
						32'b????_????_????_????_????_????_?1??_????:	c_dc_snoop_data = fetch_snoop_data[6];
						32'b????_????_????_????_????_????_??1?_????:	c_dc_snoop_data = fetch_snoop_data[5];
						32'b????_????_????_????_????_????_???1_????:	c_dc_snoop_data = fetch_snoop_data[4];
						32'b????_????_????_????_????_????_????_1???:	c_dc_snoop_data = fetch_snoop_data[3];
						32'b????_????_????_????_????_????_????_?1??:	c_dc_snoop_data = fetch_snoop_data[2];
						32'b????_????_????_????_????_????_????_??1?:	c_dc_snoop_data = fetch_snoop_data[1];
						32'b????_????_????_????_????_????_????_???1:	c_dc_snoop_data = fetch_snoop_data[0];
						endcase
					end
				end else begin
					c_dc_snoop_data_resp = r_dc_snoop_data_resp;
					c_dc_snoop_data = r_dc_snoop_data;
				end
			end
		end
														
	
		
		wire [2:0]rdline_moesi[0:NSETS-1];
		wire [NSETS-1:0]match_rdline;
		wire [NSETS-1:0]match_vacant;
		reg  [$clog2(NSETS)-1:0]r_next_evict, c_next_evict;
		reg  [$clog2(NSETS)-1:0]r_last_evict, c_last_evict;
		reg  [18:0]r_rand;
		assign orand = r_rand[0];
		always @(posedge clk) 
		if (reset) begin
			r_rand <= 1;	
		end else begin
			r_rand <= {r_rand[17:0], irand^r_rand[18]^r_rand[11]^r_rand[0]};
		end
		//wire [$clog2(NSETS)-1:0]next_evict = r_next_evict^r_rand;
		wire [$clog2(NSETS)-1:0]next_evict = (wenable0 && match_ok_write[0][r_next_evict] ? r_next_evict^1:r_next_evict); // avoid replacing entries that are being written - FIXME - handle multiple write ports
		wire [$clog2(NSETS)-1:0]update_evict = ((r_next_evict^r_rand[$clog2(NSETS)-1:0]) == r_last_evict ? r_next_evict^5'h9: r_next_evict^r_rand[$clog2(NSETS)-1:0]);

		reg [2:0]incoming_moesi;

		if (NSETS == 16) begin
			always @(*) begin
				c_dc_wdata = r_dc_wdata;
				c_dc_waddr = r_dc_waddr;
				c_dc_waddr_snoop = WSNOOP_WRITE_LINE_OWNED_L2;
				c_dc_waddr_trans = 0;
				wl = 0;
				wm = 0;
				c_next_evict = (r_dc_waddr_req&dc_waddr_ack?update_evict:r_next_evict);
				c_last_evict = (r_dc_waddr_req&dc_waddr_ack?next_evict:r_last_evict);
				c_dc_waddr_req = (reset?0:r_dc_waddr_req&!dc_waddr_ack);
				incoming_moesi = 3'bx;
				casez(dc_rdata_resp) // synthesis full_case parallel_case
				3'b1??:	incoming_moesi = C_M;
				3'b01?:	incoming_moesi = C_E;
				3'b00?:	incoming_moesi = C_S;
				endcase
				c_dc_rdata_ack = 1;
				if (dc_rdata_req) begin
					casez (match_rdline&~match_vacant) // synthesis full_case parallel_case
					16'b1???_????_????_????:	wm[15] = 1;
					16'b?1??_????_????_????:	wm[14] = 1;
					16'b??1?_????_????_????:	wm[13] = 1;
					16'b???1_????_????_????:	wm[12] = 1;
					16'b????_1???_????_????:	wm[11] = 1;
					16'b????_?1??_????_????:	wm[10] = 1;
					16'b????_??1?_????_????:	wm[9] = 1;
					16'b????_???1_????_????:	wm[8] = 1;
					16'b????_????_1???_????:	wm[7] = 1;
					16'b????_????_?1??_????:	wm[6] = 1;
					16'b????_????_??1?_????:	wm[5] = 1;
					16'b????_????_???1_????:	wm[4] = 1;
					16'b????_????_????_1???:	wm[3] = 1;
					16'b????_????_????_?1??:	wm[2] = 1;
					16'b????_????_????_??1?:	wm[1] = 1;
					16'b????_????_????_???1:	wm[0] = 1;
					16'b0000_0000_0000_0000: 
						if (dc_rdata_resp[0]) begin
							casez (match_vacant&~writing_set[0]) // synthesis full_case parallel_case		// FIXME for more write ports
							16'b1000_0000_0000_0000:	wl[15] = 1;
							16'b?100_0000_0000_0000:	wl[14] = 1;
							16'b??10_0000_0000_0000:	wl[13] = 1;
							16'b???1_0000_0000_0000:	wl[12] = 1;
							16'b????_1000_0000_0000:	wl[11] = 1;
							16'b????_?100_0000_0000:	wl[10] = 1;
							16'b????_??10_0000_0000:	wl[9] = 1;
							16'b????_???1_0000_0000:	wl[8] = 1;
							16'b????_????_1000_0000:	wl[7] = 1;
							16'b????_????_?100_0000:	wl[6] = 1;
							16'b????_????_??10_0000:	wl[5] = 1;
							16'b????_????_???1_0000:	wl[4] = 1;
							16'b????_????_????_1000:	wl[3] = 1;
							16'b????_????_????_?100:	wl[2] = 1;
							16'b????_????_????_??10:	wl[1] = 1;
							16'b????_????_????_???1:	wl[0] = 1;
							16'b0000_0000_0000_0000:		// have to evict
								begin
									case (rdline_moesi[next_evict]) 
									C_M,
									C_O:		begin
													c_dc_waddr_req = 1;// need to write back
													c_dc_rdata_ack = !(r_dc_waddr_req&!dc_waddr_ack);
													if (!r_dc_waddr_req|dc_waddr_ack) begin
														c_dc_wdata = fetch_wdata[next_evict];
														c_dc_waddr = {fetch_wtags[next_evict],dc_raddr[11:ACACHE_LINE_SIZE]};
													end
												end
									default:	;
									endcase
									wl[next_evict] = c_dc_rdata_ack;
								end
							endcase
						end
					endcase
				end
			end
		end else begin
			always @(*) begin
				c_dc_wdata = r_dc_wdata;
				c_dc_waddr = r_dc_waddr;
				c_dc_waddr_snoop = WSNOOP_WRITE_LINE_OWNED_L2;
				c_dc_waddr_trans = 0;
				wl = 0;
				wm = 0;
				c_next_evict = (r_dc_waddr_req&dc_waddr_ack?update_evict:r_next_evict);
				c_last_evict = (r_dc_waddr_req&dc_waddr_ack?next_evict:r_last_evict);
				c_dc_waddr_req = (reset?0:r_dc_waddr_req&!dc_waddr_ack);
				incoming_moesi = 3'bx;
				casez(dc_rdata_resp) // synthesis full_case parallel_case
				3'b1??:	incoming_moesi = C_M;
				3'b01?:	incoming_moesi = C_E;
				3'b00?:	incoming_moesi = C_S;
				endcase
				c_dc_rdata_ack = 1;
				if (dc_rdata_req) begin
					casez (match_rdline&~match_vacant) // synthesis full_case parallel_case
					32'b1???_????_????_????_????_????_????_????:	wm[31] = 1;
					32'b?1??_????_????_????_????_????_????_????:	wm[30] = 1;
					32'b??1?_????_????_????_????_????_????_????:	wm[29] = 1;
					32'b???1_????_????_????_????_????_????_????:	wm[28] = 1;
					32'b????_1???_????_????_????_????_????_????:	wm[27] = 1;
					32'b????_?1??_????_????_????_????_????_????:	wm[26] = 1;
					32'b????_??1?_????_????_????_????_????_????:	wm[25] = 1;
					32'b????_???1_????_????_????_????_????_????:	wm[24] = 1;
					32'b????_????_1???_????_????_????_????_????:	wm[23] = 1;
					32'b????_????_?1??_????_????_????_????_????:	wm[22] = 1;
					32'b????_????_??1?_????_????_????_????_????:	wm[21] = 1;
					32'b????_????_???1_????_????_????_????_????:	wm[20] = 1;
					32'b????_????_????_1???_????_????_????_????:	wm[19] = 1;
					32'b????_????_????_?1??_????_????_????_????:	wm[18] = 1;
					32'b????_????_????_??1?_????_????_????_????:	wm[17] = 1;
					32'b????_????_????_???1_????_????_????_????:	wm[16] = 1;
					32'b????_????_????_????_1???_????_????_????:	wm[15] = 1;
					32'b????_????_????_????_?1??_????_????_????:	wm[14] = 1;
					32'b????_????_????_????_??1?_????_????_????:	wm[13] = 1;
					32'b????_????_????_????_???1_????_????_????:	wm[12] = 1;
					32'b????_????_????_????_????_1???_????_????:	wm[11] = 1;
					32'b????_????_????_????_????_?1??_????_????:	wm[10] = 1;
					32'b????_????_????_????_????_??1?_????_????:	wm[9] = 1;
					32'b????_????_????_????_????_???1_????_????:	wm[8] = 1;
					32'b????_????_????_????_????_????_1???_????:	wm[7] = 1;
					32'b????_????_????_????_????_????_?1??_????:	wm[6] = 1;
					32'b????_????_????_????_????_????_??1?_????:	wm[5] = 1;
					32'b????_????_????_????_????_????_???1_????:	wm[4] = 1;
					32'b????_????_????_????_????_????_????_1???:	wm[3] = 1;
					32'b????_????_????_????_????_????_????_?1??:	wm[2] = 1;
					32'b????_????_????_????_????_????_????_??1?:	wm[1] = 1;
					32'b????_????_????_????_????_????_????_???1:	wm[0] = 1;
					32'b0000_0000_0000_0000_0000_0000_0000_0000: 
						if (dc_rdata_resp[0]) begin
							casez (match_vacant&~writing_set[0]) // synthesis full_case parallel_case		// FIXME for more write ports
							32'b1000_0000_0000_0000_0000_0000_0000_0000:	wl[31] = 1;
							32'b?100_0000_0000_0000_0000_0000_0000_0000:	wl[30] = 1;
							32'b??10_0000_0000_0000_0000_0000_0000_0000:	wl[29] = 1;
							32'b???1_0000_0000_0000_0000_0000_0000_0000:	wl[28] = 1;
							32'b????_1000_0000_0000_0000_0000_0000_0000:	wl[27] = 1;
							32'b????_?100_0000_0000_0000_0000_0000_0000:	wl[26] = 1;
							32'b????_??10_0000_0000_0000_0000_0000_0000:	wl[25] = 1;
							32'b????_???1_0000_0000_0000_0000_0000_0000:	wl[24] = 1;
							32'b????_????_1000_0000_0000_0000_0000_0000:	wl[23] = 1;
							32'b????_????_?100_0000_0000_0000_0000_0000:	wl[22] = 1;
							32'b????_????_??10_0000_0000_0000_0000_0000:	wl[21] = 1;
							32'b????_????_???1_0000_0000_0000_0000_0000:	wl[20] = 1;
							32'b????_????_????_1000_0000_0000_0000_0000:	wl[19] = 1;
							32'b????_????_????_?100_0000_0000_0000_0000:	wl[18] = 1;
							32'b????_????_????_??10_0000_0000_0000_0000:	wl[17] = 1;
							32'b????_????_????_???1_0000_0000_0000_0000:	wl[16] = 1;
							32'b????_????_????_????_1000_0000_0000_0000:	wl[15] = 1;
							32'b????_????_????_????_?100_0000_0000_0000:	wl[14] = 1;
							32'b????_????_????_????_??10_0000_0000_0000:	wl[13] = 1;
							32'b????_????_????_????_???1_0000_0000_0000:	wl[12] = 1;
							32'b????_????_????_????_????_1000_0000_0000:	wl[11] = 1;
							32'b????_????_????_????_????_?100_0000_0000:	wl[10] = 1;
							32'b????_????_????_????_????_??10_0000_0000:	wl[9] = 1;
							32'b????_????_????_????_????_???1_0000_0000:	wl[8] = 1;
							32'b????_????_????_????_????_????_1000_0000:	wl[7] = 1;
							32'b????_????_????_????_????_????_?100_0000:	wl[6] = 1;
							32'b????_????_????_????_????_????_??10_0000:	wl[5] = 1;
							32'b????_????_????_????_????_????_???1_0000:	wl[4] = 1;
							32'b????_????_????_????_????_????_????_1000:	wl[3] = 1;
							32'b????_????_????_????_????_????_????_?100:	wl[2] = 1;
							32'b????_????_????_????_????_????_????_??10:	wl[1] = 1;
							32'b????_????_????_????_????_????_????_???1:	wl[0] = 1;
							32'b0000_0000_0000_0000_0000_0000_0000_0000:		// have to evict
								begin
									case (rdline_moesi[next_evict]) 
									C_M,
									C_O:		begin
													c_dc_waddr_req = 1;// need to write back
													c_dc_rdata_ack = !(r_dc_waddr_req&!dc_waddr_ack);
													if (!r_dc_waddr_req|dc_waddr_ack) begin
														c_dc_wdata = fetch_wdata[next_evict];
														c_dc_waddr = {fetch_wtags[next_evict],dc_raddr[11:ACACHE_LINE_SIZE]};
													end
												end
									default:	;
									endcase
									wl[next_evict] = c_dc_rdata_ack;
								end
							endcase
						end
					endcase
				end
			end
		end

		always @(posedge clk) begin
			r_dc_waddr_req <= c_dc_waddr_req;
			r_dc_wdata <= c_dc_wdata;
			r_dc_waddr <= c_dc_waddr;
			r_dc_waddr_snoop <= c_dc_waddr_snoop;
			r_dc_waddr_trans <= c_dc_waddr_trans;
`ifdef SIMD
if (c_dc_waddr_req && simd_enable)$display("%d dc1 write addr=%x data=%x",$time,c_dc_waddr,c_dc_wdata);
`endif
			r_next_evict <= (reset?0:c_next_evict);
			r_last_evict <= (reset?0:c_last_evict);
		end
			
		wire [2:0]mm[0:WRITEPORTS-1][0:NSETS-1];
		wire [NSETS-1:0]match[0:READPORTS-1];
wire [31:0]match_0=match[0];
wire [31:0]match_1=match[1];
		wire [2:0]mr[0:READPORTS-1][0:NSETS-1];
		wire [NSETS-1:0]match_need_o[0:READPORTS-1];
		
		wire [NSETS-1:0]match_must_invalidate[0:WRITEPORTS-1];	// we need to invalidate other entries and switch this exclusive and retry (to modified)
		wire [NSETS-1:0]matchw[0:WRITEPORTS-1];

		reg [(CACHE_LINE_SIZE/8)-1:0]mask[0:WRITEPORTS-1];

		for (W = 0; W < WRITEPORTS; W=W+1) begin :w

			if (RV==64) begin
				assign ww[W] = {wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W]};
			end else begin
				assign ww[W] = {wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W],
				                wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W], wdata[W]};
			end



			if (RV==64) begin
				always @(*)
				if (!wenable[W]) begin
					mask[W] = 0;
				end else
				case (waddr[W][5:3]) // synthesis full_case parallel_case
				0: mask[W] = {56'b0, wmask[W]};
				1: mask[W] = {48'b0, wmask[W], 8'b0};
				2: mask[W] = {40'b0, wmask[W], 16'b0};
				3: mask[W] = {32'b0, wmask[W], 24'b0};
				4: mask[W] = {24'b0, wmask[W], 32'b0};
				5: mask[W] = {16'b0, wmask[W], 40'b0};
				6: mask[W] = {8'b0,  wmask[W], 48'b0};
				7: mask[W] = {       wmask[W], 56'b0};
				endcase
			end else begin
				always @(*)
				if (!wenable[W]) begin
					mask[W] = 0;
				end else
				case (waddr[W][5:3]) // synthesis full_case parallel_case
				0:  mask[W] = {60'b0, wmask[W]};
				1:  mask[W] = {56'b0, wmask[W], 4'b0};
				2:  mask[W] = {52'b0, wmask[W], 8'b0};
				3:  mask[W] = {48'b0, wmask[W], 12'b0};
				4:  mask[W] = {44'b0, wmask[W], 16'b0};
				5:  mask[W] = {40'b0, wmask[W], 20'b0};
				6:  mask[W] = {36'b0, wmask[W], 24'b0};
				7:  mask[W] = {32'b0, wmask[W], 28'b0};
				8:  mask[W] = {28'b0, wmask[W], 32'b0};
				9:  mask[W] = {24'b0, wmask[W], 36'b0};
				10: mask[W] = {20'b0, wmask[W], 40'b0};
				11: mask[W] = {16'b0, wmask[W], 44'b0};
				12: mask[W] = {12'b0, wmask[W], 48'b0};
				13: mask[W] = {8'b0,  wmask[W], 52'b0};
				14: mask[W] = {4'b0,  wmask[W], 56'b0};
				15: mask[W] = {       wmask[W], 60'b0};
				endcase
			end
			assign whit_ok_write[W] = |match_ok_write[W];
			assign writing_set[W] = wenable[W]?match_ok_write[W]:0;
			assign whit_must_invalidate[W] = |match_must_invalidate[W];
			//assign wwait[W] = |(wl&match_ok_write[W]);
			assign wwait[W] = |(wl&match_ok_write[W]);// || (dc_snoop_addr_req&&dc_snoop_addr_ack&&|match_ok_write[W]&&dc_snoop_addr[NPHYS-1:ACACHE_LINE_SIZE]==waddr[W][NPHYS-1:ACACHE_LINE_SIZE]);
		end

`ifdef PSYNTH
		wire [NSETS-1:0]write_err;
`endif

		for (S = 0; S < NSETS; S = S+1) begin

`ifdef PSYNTH
            dc1_xdata #(.NPHYS(NPHYS))data(.clk(clk),
                .wen(wl[S]),
                .wenb(match_ok_write[0][S]?mask[0]:64'b0),
                .waddr0(dc_raddr[11:ACACHE_LINE_SIZE]),
                .din0(dc_rdata),
                .waddr1(waddr[0][11:ACACHE_LINE_SIZE]),
                .din1(ww[0]),
                .raddr_0(load.req[0].addr[11:ACACHE_LINE_SIZE]),
                .dout_0(rd[0][S]),
                .raddr_1(load.req[1].addr[11:ACACHE_LINE_SIZE]),
                .dout_1(rd[1][S]),
                .raddr_2(dc_snoop_addr[11:ACACHE_LINE_SIZE]),
                .dout_2(fetch_snoop_data[S]),
                .dout_3(fetch_wdata[S]));
			assign write_err[S] = wl[S] && (|mask[0] && match_ok_write[0][S]);

`else
			reg [CACHE_LINE_SIZE-1:0]r_data[0:NENTRIES-1];

			assign fetch_snoop_data[S] = r_data[dc_snoop_addr[11:ACACHE_LINE_SIZE]];
			assign fetch_wdata[S] = r_data[dc_raddr[11:ACACHE_LINE_SIZE]];
			for (R = 0; R < READPORTS; R=R+1) begin 
				assign rd[R][S]     = r_data[load.req[R].addr[11:ACACHE_LINE_SIZE]];
			end
			for (W = 0; W < WRITEPORTS; W=W+1) begin :w
				for (B=0; B<(CACHE_LINE_SIZE/8); B=B+1) begin
					always @(posedge clk)
					if (wl[S]) begin
`ifdef SIMD
if (mask[W][B] && match_ok_write[W][S]) $display("%d cache write error %d %d", $time, S, B);
`endif
						r_data[dc_raddr[11:ACACHE_LINE_SIZE]][B*8+7:B*8] <= dc_rdata[B*8+7:B*8];
					end else
					if (mask[W][B] && match_ok_write[W][S]) begin
						r_data[waddr[W][11:ACACHE_LINE_SIZE]][B*8+7:B*8] <= ww[W][B*8+7:B*8];
					end
				end
			end
`endif


			wire [NPHYS-1:12]fetch_rd_tags[0:READPORTS-1];
			wire [NPHYS-1:12]fetch_wr_tags[0:WRITEPORTS-1];
			wire [NPHYS-1:12]fetch_snoop_tags;
`ifdef PSYNTH
            dc1_tdata #(.NPHYS(NPHYS))tags(.clk(clk),
                .wen(wl[S]),
                .waddr(dc_raddr[11:ACACHE_LINE_SIZE]),
                .din(dc_raddr[NPHYS-1:12]),
                .raddr_0(load.req[0].addr[11:ACACHE_LINE_SIZE]),
                .dout_0(fetch_rd_tags[0]),
                .raddr_1(load.req[1].addr[11:ACACHE_LINE_SIZE]),
                .dout_1(fetch_rd_tags[1]),
                .raddr_2(dc_snoop_addr[11:ACACHE_LINE_SIZE]),
                .dout_2(fetch_snoop_tags),
                .raddr_3(waddr[0][11:ACACHE_LINE_SIZE]),
                .dout_3(fetch_wr_tags[0]),
                .dout_4(fetch_wtags[S]));	// write port address
`else
			reg   [NPHYS-1:12]r_tags[0:NENTRIES-1];

			always @(posedge clk)
			if (wl[S]) begin
				r_tags[dc_raddr[11:ACACHE_LINE_SIZE]] <= dc_raddr[NPHYS-1:12];
			end

			assign fetch_wtags[S] = r_tags[dc_raddr[11:ACACHE_LINE_SIZE]];
			assign fetch_snoop_tags = r_tags[dc_snoop_addr[11:ACACHE_LINE_SIZE]];

			for (W = 0; W < WRITEPORTS; W=W+1) begin 
				assign fetch_wr_tags[W]                = r_tags[waddr[W][11:ACACHE_LINE_SIZE]];
			end
			for (R = 0; R < READPORTS; R=R+1) begin 
				assign fetch_rd_tags[R] = r_tags[load.req[R].addr[11:ACACHE_LINE_SIZE]];
			end
`endif
			for (R = 0; R < READPORTS; R=R+1) begin 
				assign mr[R][S] = r_moesi[S][load.req[R].addr[11:ACACHE_LINE_SIZE]];
				assign match[R][S] = (mr[R][S]!=C_I) && fetch_rd_tags[R] == load.req[R].addr[NPHYS-1:12];
				assign match_need_o[R][S] = (mr[R][S]==C_O) || (mr[R][S]==C_S);
			end
			assign match_rdline[S] = fetch_wtags[S] == dc_raddr[NPHYS-1:12];
			assign match_snoop[S] = (r_moesi[S][dc_snoop_addr[11:ACACHE_LINE_SIZE]][2:0]!=C_I) && fetch_snoop_tags == dc_snoop_addr[NPHYS-1:12];
			assign current_moesi[S] = r_moesi[S][dc_snoop_addr[11:ACACHE_LINE_SIZE]];
			assign match_dirty[S] = current_moesi[S][2];
			assign match_owned[S] = current_moesi[S] == C_O;
			assign match_exclusive[S] = current_moesi[S]==C_E || current_moesi[S][2];


			always @(*) begin
				if (match_snoop[S] && dc_snoop_addr_req&dc_snoop_addr_ack) begin
					case (dc_snoop_snoop) // synthesis full_case
					SNOOP_READ_UNSHARED:	begin
												s[S] = 0;
												new_moesi[S] = 3'bx;
											end
					SNOOP_READ_SHARED:		begin
												s[S] = 1;
												new_moesi[S] = (match_dirty[S]|match_owned[S]?C_O:C_S);
											end
					SNOOP_READ_EXCLUSIVE,
					SNOOP_READ_INVALID:		begin
												s[S] = 1;
												new_moesi[S] = C_I;
											end
					endcase
				end else begin
					s[S] = 0;
					new_moesi[S] = 3'bx;
				end
			end

			assign rdline_moesi[S] = r_moesi[S][dc_raddr[11:ACACHE_LINE_SIZE]];
			assign match_vacant[S] = rdline_moesi[S] == C_I;

			for (W = 0; W < WRITEPORTS; W=W+1) begin 
				assign matchw[W][S]                = fetch_wr_tags[W] == waddr[W][NPHYS-1:12];
				assign mm[W][S]                    = r_moesi[S][waddr[W][11:ACACHE_LINE_SIZE]];
				assign match_ok_write[W][S]        = (mm[W][S]==C_E || mm[W][S]==C_M) && matchw[W][S];	// ME
				assign match_must_invalidate[W][S] = (mm[W][S][0]) && matchw[W][S];						// OS
			end

			for (M = 0; M < NENTRIES; M=M+1) begin
				always @(posedge clk) begin	// FIXME (for mutiple write ports
					casez ({reset,
							(wl[S]||wm[S]) && (dc_raddr[11:ACACHE_LINE_SIZE] == M),
					        s[S] && (dc_snoop_addr[11:ACACHE_LINE_SIZE] == M),
							wenable[0] && match_ok_write[0][S] && (mm[0][S] == C_E) && (waddr[0][11:ACACHE_LINE_SIZE]==M)}) // synthesis full_case parallel_case
					4'b1???: r_moesi[S][M] <= C_I;
					4'b01??: r_moesi[S][M] <= incoming_moesi;
					4'b001?: r_moesi[S][M] <= new_moesi[S];
					4'b0001: r_moesi[S][M] <= C_M;
					4'b0000: ;
					endcase
				end 
			end
		end

		for (R = 0; R < READPORTS; R=R+1) begin :r
			assign load.ack[R].hit = |match[R];
			assign load.ack[R].hit_need_o = |(match[R]&match_need_o[R]);

			if (NSETS == 16) begin
				always @(*) begin 
					casez (match[R]) // synthesis full_case parallel_case
					16'b????_????_????_???1: rdd[R] = rd[R][0];
					16'b????_????_????_??1?: rdd[R] = rd[R][1];
					16'b????_????_????_?1??: rdd[R] = rd[R][2];
					16'b????_????_????_1???: rdd[R] = rd[R][3];

					16'b????_????_???1_????: rdd[R] = rd[R][4];
					16'b????_????_??1?_????: rdd[R] = rd[R][5];
					16'b????_????_?1??_????: rdd[R] = rd[R][6];
					16'b????_????_1???_????: rdd[R] = rd[R][7];

					16'b????_???1_????_????: rdd[R] = rd[R][8];
					16'b????_??1?_????_????: rdd[R] = rd[R][9];
					16'b????_?1??_????_????: rdd[R] = rd[R][10];
					16'b????_1???_????_????: rdd[R] = rd[R][11];

					16'b???1_????_????_????: rdd[R] = rd[R][12];
					16'b??1?_????_????_????: rdd[R] = rd[R][13];
					16'b?1??_????_????_????: rdd[R] = rd[R][14];
					16'b1???_????_????_????: rdd[R] = rd[R][15];
					default: rdd[R] = 512'bx;
					endcase
				end
			end else begin
				always @(*) begin 
					casez (match[R]) // synthesis full_case parallel_case
					32'b????_????_????_????_????_????_????_???1: rdd[R] = rd[R][0];
					32'b????_????_????_????_????_????_????_??1?: rdd[R] = rd[R][1];
					32'b????_????_????_????_????_????_????_?1??: rdd[R] = rd[R][2];
					32'b????_????_????_????_????_????_????_1???: rdd[R] = rd[R][3];

					32'b????_????_????_????_????_????_???1_????: rdd[R] = rd[R][4];
					32'b????_????_????_????_????_????_??1?_????: rdd[R] = rd[R][5];
					32'b????_????_????_????_????_????_?1??_????: rdd[R] = rd[R][6];
					32'b????_????_????_????_????_????_1???_????: rdd[R] = rd[R][7];

					32'b????_????_????_????_????_???1_????_????: rdd[R] = rd[R][8];
					32'b????_????_????_????_????_??1?_????_????: rdd[R] = rd[R][9];
					32'b????_????_????_????_????_?1??_????_????: rdd[R] = rd[R][10];
					32'b????_????_????_????_????_1???_????_????: rdd[R] = rd[R][11];

					32'b????_????_????_????_???1_????_????_????: rdd[R] = rd[R][12];
					32'b????_????_????_????_??1?_????_????_????: rdd[R] = rd[R][13];
					32'b????_????_????_????_?1??_????_????_????: rdd[R] = rd[R][14];
					32'b????_????_????_????_1???_????_????_????: rdd[R] = rd[R][15];

					32'b????_????_????_???1_????_????_????_????: rdd[R] = rd[R][16];
					32'b????_????_????_??1?_????_????_????_????: rdd[R] = rd[R][17];
					32'b????_????_????_?1??_????_????_????_????: rdd[R] = rd[R][18];
					32'b????_????_????_1???_????_????_????_????: rdd[R] = rd[R][19];

					32'b????_????_???1_????_????_????_????_????: rdd[R] = rd[R][20];
					32'b????_????_??1?_????_????_????_????_????: rdd[R] = rd[R][21];
					32'b????_????_?1??_????_????_????_????_????: rdd[R] = rd[R][22];
					32'b????_????_1???_????_????_????_????_????: rdd[R] = rd[R][23];

					32'b????_???1_????_????_????_????_????_????: rdd[R] = rd[R][24];
					32'b????_??1?_????_????_????_????_????_????: rdd[R] = rd[R][25];
					32'b????_?1??_????_????_????_????_????_????: rdd[R] = rd[R][26];
					32'b????_1???_????_????_????_????_????_????: rdd[R] = rd[R][27];

					32'b???1_????_????_????_????_????_????_????: rdd[R] = rd[R][28];
					32'b??1?_????_????_????_????_????_????_????: rdd[R] = rd[R][29];
					32'b?1??_????_????_????_????_????_????_????: rdd[R] = rd[R][30];
					32'b1???_????_????_????_????_????_????_????: rdd[R] = rd[R][31];
					default: rdd[R] = 512'bx;
					endcase
				end
			end
			reg [RV-1:0]rxd;
			assign load.ack[R].data = rxd;
			if (RV==64) begin
				always @(*) begin
					case (load.req[R].addr[5:3]) // synthesis full_case parallel_case
					0: rxd = rdd[R][63:0];
					1: rxd = rdd[R][127:64];
					2: rxd = rdd[R][191:128];
					3: rxd = rdd[R][255:192];
					4: rxd = rdd[R][319:256];
					5: rxd = rdd[R][383:320];
					6: rxd = rdd[R][447:384];
					7: rxd = rdd[R][511:448];
					endcase
				end
			end else begin
				always @(*) begin
					case (load.req[R].addr[5:2]) // synthesis full_case parallel_case
					0: rxd = rdd[R][31:0];
					1: rxd = rdd[R][63:32];
					2: rxd = rdd[R][95:64];
					3: rxd = rdd[R][127:96];
					4: rxd = rdd[R][159:128];
					5: rxd = rdd[R][191:160];
					6: rxd = rdd[R][223:192];
					7: rxd = rdd[R][255:224];
					8: rxd = rdd[R][287:256];
					9: rxd = rdd[R][319:288];
					10: rxd = rdd[R][351:320];
					11: rxd = rdd[R][383:352];
					12: rxd = rdd[R][415:384];
					13: rxd = rdd[R][447:416];
					14: rxd = rdd[R][479:448];
					15: rxd = rdd[R][511:480];
					endcase
				end
			end
		end
	end endgenerate

`ifdef AWS_DEBUG
    wire [3:0]xxtrig_sel;
    wire [31:0]xxtrig_cmp;
    wire [15:0]xxtrig_count;
    wire [39:0]xxtrig_ticks;


    reg xls_trig;
    assign dc_trig=xls_trig;
    always @(*)
    case (xxtrig_sel)
    0: xls_trig = wenable0 && waddr0[31:3]==xxtrig_cmp[31:3];
    1: xls_trig = wenable0 && waddr0[31:3]==xxtrig_cmp[31:3] && wdata0[31:0]==xxtrig_ticks[31:0];
    2: xls_trig = wenable0 && wdata0[31:0]==xxtrig_ticks[31:0];
	3: xls_trig = |write_err;
    default: xls_trig=0;
	endcase

	vio_cpu vio_ls_trig(.clk(clk),
            // outputs
             .xxtrig_sel(xxtrig_sel),
             .xxtrig_cmp(xxtrig_cmp),
             .xxtrig_count(xxtrig_count),
             .xxtrig_ticks(xxtrig_ticks)
            );


ila_dc ila_dc(.clk(clk),
	.wenable0(wenable0),
	.waddr0({waddr0,3'b0}),	// 52
	.wdata0(wdata0),	// 64
	.wmask0(wmask0),	// 8
	.whit_ok_write0(whit_ok_write0),
	.whit_must_invalidate0(whit_must_invalidate0),
	.wwait0(wwait0),
	.wm(wm),			// 16
	.wl(wl),			// 16
	.match_ok_write(match_ok_write[0]),	// 16
    .dc_waddr_req(dc_waddr_req),
    .dc_waddr_ack(dc_waddr_ack),
	.dc_waddr({dc_waddr[31:ACACHE_LINE_SIZE],6'b0}),	// 32
	.next_evict(next_evict),		// 5
    .dc_rdata_req(dc_rdata_req),
    .dc_rdata_ack(dc_rdata_ack),
    .dc_raddr({dc_raddr[31:ACACHE_LINE_SIZE],6'b0}),    //32
	.write_err(write_err),	//16
	.xxtrig(xxtrig));
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
