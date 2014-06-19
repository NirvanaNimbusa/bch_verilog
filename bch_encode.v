`timescale 1ns / 1ps

`include "bch_defs.vh"

module bch_encode #(
	parameter [`BCH_PARAM_SZ-1:0] P = `BCH_SANE,
	parameter BITS = 1,
	parameter PIPELINE_STAGES = 0
) (
	input clk,
	input start,				/* First cycle */
	input ce,				/* Accept input word/cycle output word */
	input [BITS-1:0] data_in,		/* Input data */
	output [BITS-1:0] data_out,		/* Encoded output */
	output first,				/* First output cycle */
	output reg last = 0,			/* Last output cycle */
	output data_bits,			/* Current cycle is data */
	output ecc_bits,			/* Current cycle is ecc */
	output ready				/* Can accept data */
);
	`include "bch.vh"
	localparam M = `BCH_M(P);

	/* Calculate least common multiple which has x^2t .. x as its roots */
	function [`BCH_ECC_BITS(P)-1:0] encoder_poly;
		input dummy;
		integer nk;
		integer i;
		integer j;
		integer a;
		integer curr;
		integer prev;
		reg [(`BCH_ECC_BITS(P)+1)*M-1:0] poly;
		reg [`BCH_N(P)-1:0] roots;
	begin

		/* Calculate the roots for this finite field */
		roots = 0;
		for (i = 0; i < `BCH_T(P); i = i + 1) begin
			a = 2 * i + 1;
			for (j = 0; j < M; j = j + 1) begin
				roots[a] = 1;
				a = (2 * a) % `BCH_N(P);
			end
		end

		nk = 0;
		poly = 1;
		a = lpow(M, 0);
		for (i = 0; i < `BCH_N(P); i = i + 1) begin
			if (roots[i]) begin
				prev = 0;
				poly[(nk+1)*M+:M] = 1;
				for (j = 0; j <= nk; j = j + 1) begin
					curr = poly[j*M+:M];
					poly[j*M+:M] = finite_mult(M, curr, a) ^ prev;
					prev = curr;
				end
				nk = nk + 1;
			end
			a = mul1(M, a);
		end

		encoder_poly = 0;
		for (i = 0; i < nk; i = i + 1)
			encoder_poly[i] = poly[i*M+:M] ? 1 : 0;
	end
	endfunction

	function [BITS-1:0] reverse;
		input [BITS-1:0] in;
		integer i;
	begin
		for (i = 0; i < BITS; i = i + 1)
			reverse[i] = in[BITS - i - 1];
	end
	endfunction

	localparam TCQ = 1;
	localparam ENC = encoder_poly(0);

	/* Data cycles required */
	localparam DATA_CYCLES = PIPELINE_STAGES + (`BCH_DATA_BITS(P) + BITS - 1) / BITS;

	/* ECC cycles required */
	localparam ECC_CYCLES = (`BCH_ECC_BITS(P) + BITS - 1) / BITS;

	/* Total output cycles required (always at least 2) */
	localparam CODE_CYCLES = DATA_CYCLES + ECC_CYCLES;

	localparam signed SHIFT = BITS - `BCH_ECC_BITS(P);

	localparam SWITCH = lfsr_count(M, DATA_CYCLES - 2);
	localparam DONE = lfsr_count(M, CODE_CYCLES - 3);
	localparam REM = `BCH_DATA_BITS(P) % BITS;
	localparam RUNT = BITS - REM;

	if (PIPELINE_STAGES > 1)
		encode_only_supports_1_pipeline_stage u_eos1ps();

	reg [`BCH_ECC_BITS(P)-1:0] lfsr = 0;
	wire [`BCH_ECC_BITS(P)-1:0] in_enc;
	wire [`BCH_ECC_BITS(P)-1:0] in_enc_pipelined;
	wire [`BCH_ECC_BITS(P)-1:0] lfsr_enc;
	wire [`BCH_ECC_BITS(P)-1:0] lfsr_shifted;
	wire [BITS-1:0] data_in_pipelined;
	wire [BITS-1:0] output_mask;
	wire [BITS-1:0] shifted_in;
	wire [M-1:0] count;
	reg load_lfsr = 0;
	reg busy = 0;
	reg start_last = 0;

	if (CODE_CYCLES < 3)
		assign count = 0;
	else
		lfsr_counter #(M) u_counter(
			.clk(clk),
			.reset(ce && start),
			.ce(ce && busy),
			.count(count)
		);

	/*
	 * Shift input so that pad the start with 0's, and finish on the final
	 * bit.
	 */
	generate
		if (REM) begin
			reg [RUNT-1:0] runt = 0;
			assign shifted_in = (data_in << RUNT) | (start ? 0 : runt);
			always @(posedge clk)
				if (ce)
					runt <= #TCQ data_in << REM;
		end else
			assign shifted_in = data_in;
	endgenerate

	lfsr_term #(`BCH_ECC_BITS(P), ENC, BITS) u_in_terms(
		.in(reverse(shifted_in)),
		.out(in_enc)
	);

	pipeline_ce #(PIPELINE_STAGES > 0) u_enc_pipeline [`BCH_ECC_BITS(P)] (
		.clk(clk),
		.ce(ce),
		.i(in_enc),
		.o(in_enc_pipelined)
	);

	pipeline_ce #(PIPELINE_STAGES) u_data_pipeline [BITS] (
		.clk(clk),
		.ce(ce),
		.i(data_in),
		.o(data_in_pipelined)
	);

	/*
	 * The below in equivalent to one instance with the vector input being
	 * data & lfsr. However, with this arrangement, its easy to pipeline
	 * the incoming data to reduce the number of gates/inputs between lfsr
	 * stages.
	 */
	wire [BITS-1:0] lfsr_input;
	assign lfsr_input = SHIFT > 0 ? (lfsr << SHIFT) : (lfsr >> -SHIFT);
	lfsr_term #(`BCH_ECC_BITS(P), ENC, BITS) u_lfsr_terms(
		.in(lfsr_input),
		.out(lfsr_enc)
	);

	assign first = PIPELINE_STAGES ? start_last : (start && !busy);
	assign data_bits = (start && !PIPELINE_STAGES) || load_lfsr;
	assign ecc_bits = (busy || last) && !data_bits;
	assign output_mask = last ? {RUNT{1'b1}} : {BITS{1'b1}};
	assign data_out = data_bits ? data_in_pipelined : (reverse(lfsr_input) & output_mask);
	assign ready = !busy;

	always @(posedge clk) begin
		if (ce) begin
			start_last <= #TCQ start && !busy;
			if (start) begin
				last <= #TCQ CODE_CYCLES < 3; /* First cycle is last cycle */
				busy <= #TCQ 1;
			end else if (count == DONE && busy) begin
				last <= #TCQ busy;
				busy <= #TCQ !PIPELINE_STAGES;
			end else if (last) begin
				last <= #TCQ 0;
				busy <= #TCQ 0;
			end

			if (start)
				load_lfsr <= #TCQ DATA_CYCLES > 1;
			else if (count == SWITCH)
				load_lfsr <= #TCQ 1'b0;

			if (start)
				lfsr <= #TCQ PIPELINE_STAGES ? 0 : in_enc_pipelined;
			else if (load_lfsr)
				lfsr <= #TCQ (lfsr << BITS) ^ lfsr_enc ^ in_enc_pipelined;
			else if (busy)
				lfsr <= #TCQ lfsr << BITS;
		end

	end
endmodule
