//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// Instruction pipeline L1 data cache data stage.
// - Detect cache miss or hit based on tag information. 
// - Perform alignment for various sizes of stores. 
// - This stage contains storage for the cache data and controls reading and writing it.
// - Handle atomic memory operations (synchronized store/load)
// - Drive signals to update LRU
// 

module dcache_data_stage(
	input                                     clk,
	input                                     reset,
                                              
	// From dcache tag stage                  
	input                                     dt_instruction_valid,
	input decoded_instruction_t               dt_instruction,
	input [`VECTOR_LANES - 1:0]               dt_mask_value,
	input thread_idx_t                        dt_thread_idx,
	input l1d_addr_t                          dt_request_addr,
	input vector_t                            dt_store_value,
	input subcycle_t                          dt_subcycle,
	input                                     dt_valid[`L1D_WAYS],
	input l1d_tag_t                           dt_tag[`L1D_WAYS],
	input [2:0]                               dt_lru_flags,
	
	// To dcache_tag_stage
	output logic                              dd_update_lru_en,
	output logic[2:0]                         dd_update_lru_flags,
	output l1d_set_idx_t                      dd_update_lru_set,
                                              
	// To writeback stage                     
	output                                    dd_instruction_valid,
	output decoded_instruction_t              dd_instruction,
	output [`VECTOR_LANES - 1:0]              dd_lane_mask,
	output thread_idx_t                       dd_thread_idx,
	output l1d_addr_t                         dd_request_addr,
	output subcycle_t                         dd_subcycle,
	output logic                              dd_rollback_en,
	output scalar_t                           dd_rollback_pc,
	output logic                              dd_sync_store_success,
	output [`CACHE_LINE_BITS - 1:0]           dd_load_data,

	// To control registers (these signals are unregistered)
	output                                    dd_creg_write_en,
	output                                    dd_creg_read_en,
	output control_register_t                 dd_creg_index,
	output scalar_t                           dd_creg_write_val,
	
	// To thread select stage
	output logic[`THREADS_PER_CORE - 1:0]     dd_dcache_wait_oh,

	// From ring controller/L2 interconnect
	input                                     l2i_ddata_update_en,
	input l1d_way_idx_t                       l2i_ddata_update_way,
	input l1d_set_idx_t                       l2i_ddata_update_set,
	input [`CACHE_LINE_BITS - 1:0]            l2i_ddata_update_data,
	input [`L1D_WAYS - 1:0]                   l2i_dtag_update_en_oh,
	input l1d_set_idx_t                       l2i_dtag_update_set,
	input l1d_tag_t                           l2i_dtag_update_tag,
 
 	// To ring controller
	output logic                              dd_cache_miss,
	output scalar_t                           dd_cache_miss_addr,
	output thread_idx_t                       dd_cache_miss_thread_idx,
	output                                    dd_store_en,
	output [`CACHE_LINE_BYTES - 1:0]          dd_store_mask,
	output scalar_t                           dd_store_addr,
	output [`CACHE_LINE_BITS - 1:0]           dd_store_data,
	output thread_idx_t                       dd_store_thread_idx,
	output logic                              dd_store_synchronized,
	output scalar_t                           dd_store_bypass_addr,              
	output thread_idx_t                       dd_store_bypass_thread_idx,

	// From writeback stage                   
	input logic                               wb_rollback_en,
	input thread_idx_t                        wb_rollback_thread_idx,
	input pipeline_sel_t                      wb_rollback_pipeline,
	
	// Performance counters
	output logic                              perf_dcache_hit,
	output logic                              perf_dcache_miss);

	logic dcache_access_req;
	logic[`VECTOR_LANES - 1:0] word_store_mask;
	logic[3:0] byte_store_mask;
	logic[$clog2(`CACHE_LINE_WORDS) - 1:0] cache_lane_idx;
	logic[`CACHE_LINE_BITS - 1:0] endian_twiddled_data;
	scalar_t lane_store_value;
	logic is_io_address;
	scalar_t scatter_gather_ptr;
	logic[`CACHE_LINE_WORDS - 1:0] cache_lane_mask;
	logic[`CACHE_LINE_WORDS - 1:0] subcycle_mask;
	logic[`L1D_WAYS - 1:0] way_hit_oh;
	l1d_way_idx_t way_hit_idx;
	logic cache_hit;
	logic dcache_read_req;
	scalar_t dcache_request_addr;
	logic[`THREADS_PER_CORE - 1:0] thread_oh;
	logic rollback_this_stage;
	logic cache_near_miss;
	logic[2:0] new_lru_flags;
	logic dcache_store_req;
	
	assign rollback_this_stage = wb_rollback_en && wb_rollback_thread_idx == dt_thread_idx
		 && wb_rollback_pipeline == PIPE_MEM;
	assign is_io_address = dt_request_addr[31:16] == 16'hffff;
	assign dcache_access_req = dt_instruction_valid && dt_instruction.is_memory_access 
		&& dt_instruction.memory_access_type != MEM_CONTROL_REG && !is_io_address
		&& !rollback_this_stage
		&& (dt_instruction.is_load || dd_store_mask != 0);	// Skip store if mask is clear
	assign dcache_read_req = dcache_access_req && dt_instruction.is_load;
	assign dcache_store_req = dcache_access_req && !dt_instruction.is_load;
	assign dd_creg_write_en = dt_instruction_valid && dt_instruction.is_memory_access 
		&& !dt_instruction.is_load && dt_instruction.memory_access_type == MEM_CONTROL_REG;
	assign dd_creg_read_en = dt_instruction_valid && dt_instruction.is_memory_access 
		&& dt_instruction.is_load && dt_instruction.memory_access_type == MEM_CONTROL_REG;
	assign dd_creg_write_val = dt_store_value[0];
	assign dd_creg_index = dt_instruction.creg_index;
	assign dcache_request_addr = { dt_request_addr[31:`CACHE_LINE_OFFSET_WIDTH], 
		{`CACHE_LINE_OFFSET_WIDTH{1'b0}} };
	assign cache_lane_idx = dt_request_addr.offset[`CACHE_LINE_OFFSET_WIDTH - 1:2];
	assign perf_dcache_hit = cache_hit && dcache_read_req;
	assign perf_dcache_miss = !cache_hit && dcache_read_req; 
	assign dd_store_bypass_addr = dt_request_addr;
	assign dd_store_addr = dt_request_addr;
	assign dd_store_synchronized = dd_instruction.memory_access_type == MEM_SYNC
		&& !dd_instruction.is_load;
	
	// 
	// Check for cache hit
	//
	genvar way_idx;
	generate
		for (way_idx = 0; way_idx < `L1D_WAYS; way_idx++)
		begin : hit_check_logic
			assign way_hit_oh[way_idx] = dt_request_addr.tag == dt_tag[way_idx] && dt_valid[way_idx]; 
		end
	endgenerate

	assign cache_hit = |way_hit_oh;

	//
	// Write alignment
	//
	index_to_one_hot #(.NUM_SIGNALS(`THREADS_PER_CORE), .DIRECTION("LSB0")) thread_oh_gen(
		.one_hot(thread_oh),
		.index(dt_thread_idx));
	
	index_to_one_hot #(.NUM_SIGNALS(`CACHE_LINE_WORDS), .DIRECTION("MSB0")) subcycle_mask_gen(
		.one_hot(subcycle_mask),
		.index(dt_subcycle));
	
	index_to_one_hot #(.NUM_SIGNALS(`CACHE_LINE_WORDS), .DIRECTION("MSB0")) cache_lane_mask_gen(
		.one_hot(cache_lane_mask),
		.index(cache_lane_idx));
	
	always_comb
	begin
		word_store_mask = 0;
		unique case (dt_instruction.memory_access_type)
			MEM_BLOCK, MEM_BLOCK_M:	// Block vector access
				word_store_mask = dt_mask_value;
			
			MEM_SCGATH, MEM_SCGATH_M:	// Scatter/Gather access
			begin
				if (dt_mask_value & subcycle_mask)
					word_store_mask = cache_lane_mask;
				else
					word_store_mask = 0;
			end

			default:	// Scalar access
				word_store_mask = cache_lane_mask;
		endcase
	end

	// Endian swap vector data
	genvar swap_word;
	generate
		for (swap_word = 0; swap_word < `CACHE_LINE_BYTES / 4; swap_word++)
		begin : swapper
			assign endian_twiddled_data[swap_word * 32+:8] = dt_store_value[swap_word][24+:8];
			assign endian_twiddled_data[swap_word * 32 + 8+:8] = dt_store_value[swap_word][16+:8];
			assign endian_twiddled_data[swap_word * 32 + 16+:8] = dt_store_value[swap_word][8+:8];
			assign endian_twiddled_data[swap_word * 32 + 24+:8] = dt_store_value[swap_word][0+:8];
		end
	endgenerate

	assign lane_store_value = dt_store_value[`CACHE_LINE_WORDS - 1 - dt_subcycle];

	// byte_store_mask and dd_store_data.
	always_comb
	begin
		unique case (dt_instruction.memory_access_type)
			MEM_B, MEM_BX: // Byte
			begin
				unique case (dt_request_addr.offset[1:0])
					2'b00:
					begin
						byte_store_mask = 4'b1000;
						dd_store_data = {`CACHE_LINE_WORDS{dt_store_value[0][7:0], 24'd0}};
					end

					2'b01:
					begin
						byte_store_mask = 4'b0100;
						dd_store_data = {`CACHE_LINE_WORDS{8'd0, dt_store_value[0][7:0], 16'd0}};
					end

					2'b10:
					begin
						byte_store_mask = 4'b0010;
						dd_store_data = {`CACHE_LINE_WORDS{16'd0, dt_store_value[0][7:0], 8'd0}};
					end

					2'b11:
					begin
						byte_store_mask = 4'b0001;
						dd_store_data = {`CACHE_LINE_WORDS{24'd0, dt_store_value[0][7:0]}};
					end
				endcase
			end

			MEM_S, MEM_SX: // 16 bits
			begin
				if (dt_request_addr.offset[1] == 1'b0)
				begin
					byte_store_mask = 4'b1100;
					dd_store_data = {`CACHE_LINE_WORDS{dt_store_value[0][7:0], dt_store_value[0][15:8], 16'd0}};
				end
				else
				begin
					byte_store_mask = 4'b0011;
					dd_store_data = {`CACHE_LINE_WORDS{16'd0, dt_store_value[0][7:0], dt_store_value[0][15:8]}};
				end
			end

			MEM_L, MEM_SYNC: // 32 bits
			begin
				byte_store_mask = 4'b1111;
				dd_store_data = {`CACHE_LINE_WORDS{dt_store_value[0][7:0], dt_store_value[0][15:8], 
					dt_store_value[0][23:16], dt_store_value[0][31:24] }};
			end

			MEM_SCGATH, MEM_SCGATH_M:
			begin
				byte_store_mask = 4'b1111;
				dd_store_data = {`CACHE_LINE_WORDS{lane_store_value[7:0], lane_store_value[15:8], lane_store_value[23:16], 
					lane_store_value[31:24] }};
			end

			default: // Vector
			begin
				byte_store_mask = 4'b1111;
				dd_store_data = endian_twiddled_data;
			end
		endcase
	end

	// Generate store mask signals.  word_store_mask corresponds to lanes, byte_store_mask
	// corresponds to bytes within a word.  Note that byte_store_mask will always
	// have all bits set if word_store_mask has more than one bit set. That is:
	// we are either selecting some number of words within the cache line for
	// a vector transfer or some bytes within a specific word for a scalar transfer.
	genvar mask_idx;
	generate
		for (mask_idx = 0; mask_idx < `CACHE_LINE_BYTES; mask_idx++)
		begin : genmask
			assign dd_store_mask[mask_idx] = word_store_mask[mask_idx / 4]
				& byte_store_mask[mask_idx & 3];
		end
	endgenerate

	one_hot_to_index #(.NUM_SIGNALS(`L1D_WAYS)) encode_hit_way(
		.one_hot(way_hit_oh),
		.index(way_hit_idx));

	sram_1r1w #(
		.DATA_WIDTH(`CACHE_LINE_BITS), 
		.SIZE(`L1D_WAYS * `L1D_SETS)
	) l1d_data(
		// Instruction pipeline access.  Note that there is only one store port that is shared by the
		// interconnect.  If both attempt access in the same cycle, the interconnect will win and 
		// the thread will be rolled back.
		.read_en(cache_hit && dcache_read_req),
		.read_addr({way_hit_idx, dt_request_addr.set_idx}),
		.read_data(dd_load_data),
		.write_en(l2i_ddata_update_en),	
		.write_addr({l2i_ddata_update_way, l2i_ddata_update_set}),
		.write_data(l2i_ddata_update_data),
		.*);

	// Cache miss occured in the cycle the same line is being filled. If we suspend the thread here,
	// it will never receive a wakeup. Instead, just roll the thread back and let it retry.
	assign cache_near_miss = !cache_hit && dcache_read_req && |l2i_dtag_update_en_oh
		&& l2i_dtag_update_set == dt_request_addr.set_idx && l2i_dtag_update_tag == dt_request_addr.tag; 

	assign dd_cache_miss = !cache_hit && dcache_read_req && !cache_near_miss;
	assign dd_cache_miss_addr = dcache_request_addr;
	assign dd_cache_miss_thread_idx = dt_thread_idx;
	assign dd_store_en = dcache_store_req;
	assign dd_store_thread_idx = dt_thread_idx;

	// Update pseudo-LRU bits so bits along the path to this leaf point in the
	// opposite direction. Explanation of this algorithm in dcache_tag_stage.
	// Note that we also update the LRU for stores if there is a cache it.
	// We update the LRU for stores that hit cache lines, even though stores go through the
	// write buffer and don't directly update L1 cache memory.
	assign dd_update_lru_en = (cache_hit && dcache_access_req) || l2i_ddata_update_en;
	assign dd_update_lru_set = l2i_ddata_update_en ? l2i_ddata_update_set : dt_request_addr.set_idx;
	always_comb
	begin
		unique case (l2i_ddata_update_en ? l2i_ddata_update_way : way_hit_idx)
			2'd0: dd_update_lru_flags = { 2'b11, dt_lru_flags[0] };
			2'd1: dd_update_lru_flags = { 2'b01, dt_lru_flags[0] };
			2'd2: dd_update_lru_flags = { dt_lru_flags[2], 2'b01 };
			2'd3: dd_update_lru_flags = { dt_lru_flags[2], 2'b00 };
		endcase
	end

	// Suspend the thread if there is a cache miss.
	// In the near miss case (described above), don't suspend thread.
	assign dd_dcache_wait_oh = (dcache_read_req && !cache_hit && !cache_near_miss) ? thread_oh : 0;

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			dd_instruction <= 1'h0;
			dd_instruction_valid <= 1'h0;
			dd_lane_mask <= {(1+(`VECTOR_LANES-1)){1'b0}};
			dd_request_addr <= 1'h0;
			dd_rollback_en <= 1'h0;
			dd_rollback_pc <= 1'h0;
			dd_subcycle <= 1'h0;
			dd_sync_store_success <= 1'h0;
			dd_thread_idx <= 1'h0;
			// End of automatics
		end
		else
		begin
			dd_instruction_valid <= dt_instruction_valid && !rollback_this_stage;
			dd_instruction <= dt_instruction;
			dd_lane_mask <= dt_mask_value;
			dd_thread_idx <= dt_thread_idx;
			dd_request_addr <= dt_request_addr;
			dd_subcycle <= dt_subcycle;
			dd_rollback_pc <= dt_instruction.pc;

			// Make sure data is not present in more than one way.
			assert(!dcache_read_req || $onehot0(way_hit_oh));

			// Rollback on cache miss
			dd_rollback_en <= dcache_read_req && !cache_hit;
			if (is_io_address && dt_instruction_valid && dt_instruction.is_memory_access && !dt_instruction.is_load)
				$write("%c", dt_store_value[0][7:0]);
				
			// Atomic memory operations
			// XXX need to check success value from ring interface
			dd_sync_store_success <= 0;
		end
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:
