# 
# Copyright (C) 2014 Jeff Bush
# 
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
# 
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Library General Public License for more details.
# 
# You should have received a copy of the GNU Library General Public
# License along with this library; if not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
# Boston, MA  02110-1301, USA.
# 

#
# Generate a pseudorandom instruction stream.
# This is specifically constrained for the V2 microarchitecture.
#
# v0, s0 - Base registers for data segment
# v1, s1 - Computed address registers.  Guaranteed to be 64 byte aligned and in memory segment.
# v2-v8, s2-s8 - Operation registers
#
# Data memory starts at 0x100000
#

TOTAL_INSTRUCTIONS=0x8000

import random, sys

FORMS = [
	('s', 's', 's', ''),
	('v', 'v', 's', ''),
	('v', 'v', 's', '_mask'),
	('v', 'v', 's', '_invmask'),
	('v', 'v', 'v', ''),
	('v', 'v', 'v', '_mask'),
	('v', 'v', 'v', '_invmask'),
	('s', 's', 'i', ''),
	('v', 'v', 'i', ''),
	('v', 'v', 'i', '_mask'),
	('v', 'v', 'i', '_invmask'),
	('v', 's', 'i', ''),
	('v', 's', 'i', '_mask'),
	('v', 's', 'i', '_invmask')
]

BINOPS = [
	'or',
	'and',
	'xor',
	'add_i',
	'sub_i',
	'ashr',
	'shr',
	'shl'
]

UNOPS = [
#	'clz',
#	'ctz',
	'move'
]

print '# This file auto-generated by ' + sys.argv[0] + '''

			.globl _start
_start:		move s1, 15
			setcr s1, 30	; start all threads
			
			; Initialize registers
			move s3, 4051
			move s4, s3
			move s5, s3
			xor s6, s5, s4
			move s7, s6
			move s8, 0
			move v2, 0
			move v3, s3
			move v4, s4
			move v5, s5
			move v6, s6
			move v7, s7
			move_mask v3, s7, v4
			move_mask v4, s6, v5
			move_mask v5, s5, v6
			move_mask v6, s4, v7
			move_mask v7, s3, v3
			move v8, 0

			; Load memory pointers
			load_32 s0, _data_ptr
			move v0, s0

			move s8, 1
			shl s8, s8, 16
			sub_i s8, s8, 1
	loop0: 	add_i_mask v0, s8, v0, 8
			shr s8, s8, 1
			btrue s8, loop0

			; Duplicate into computed register addresses
			move v1, v0
			move s1, s0
		
			; Compute initial code branch address
			getcr s2, 0
			shl s2, s2, 2
			lea s3, branch_addrs
			add_i s2, s2, s3
			load_32 s2, (s2)
			move pc, s2
_data_ptr:	.long data

branch_addrs: .long start_strand0, start_strand1, start_strand2, start_strand3

'''

for strand in range(4):
	print 'start_strand%d:' % strand
	labelIdx = 1
	for x in range(TOTAL_INSTRUCTIONS):
		print str(labelIdx + 1) + ':',
		labelIdx = (labelIdx + 1) % 6
		
		if random.randint(0, 7) == 0:
			# Computed pointer
			if random.randint(0, 1) == 0:
				print '\t\tadd_i s1, s0, ' + str(random.randint(0, 16) * 64)
			else:
				print '\t\tadd_i v1, v0, ' + str(random.randint(0, 16) * 64)
				
			continue
			
		instType = random.randint(0, 2)
		if instType == 0:
			# Arithmetic
			typed, typea, typeb, suffix = random.choice(FORMS)
			mnemonic = random.choice(BINOPS)
			dest = random.randint(2, 8)
			rega = random.randint(2, 8)
			regb = random.randint(2, 8)
			maskreg = random.randint(2, 8)
			opstr = '\t\t' + mnemonic + suffix + ' ' + typed + str(dest) + ', '
			if suffix != '':
				opstr += 's' + str(maskreg)	+ ', ' # Add mask register
		
			opstr += typea + str(rega) + ', '
			if typeb == 'i':
				opstr += str(random.randint(0, 0x1ff))	# Immediate value
			else:
			 	opstr += typeb + str(regb)

			print opstr
		elif instType == 1:
			# Branch
			branchType = random.randint(0, 2)
			if branchType == 0:
				print '\t\tgoto ' + str(random.randint(1, 6)) + 'f'
			elif branchType == 1:
				print '\t\tbtrue s' + str(random.randint(2, 8)) + ', ' + str(random.randint(1, 6)) + 'f'
			else:
				print '\t\tbfalse s' + str(random.randint(2, 8)) + ', ' + str(random.randint(1, 6)) + 'f'
		else:
			# Memory
			opType = random.randint(0, 2)
			ptrReg = random.randint(0, 1)
			opstr = 'load' if random.randint(0, 1) else 'store'
			
			if opType == 0:
				# Block vector
				opstr += '_v v' + str(random.randint(2, 8)) + ', (s' + str(ptrReg) + ')'
			elif opType == 1:
				# Scatter/gather
				if opstr == 'load':
					opstr += '_gath '
				else:
					opstr += '_scat '

				opstr += ' v' + str(random.randint(2, 8)) + ', (v' + str(ptrReg) + ')'
 			else:
				# Scalar
				opstr += '_32 s' + str(random.randint(2, 8)) + ', (s' + str(ptrReg) + ')'
			
			print '\t\t' + opstr
			
	print '''
	1: nop
	2: nop
	3: nop
	4: nop
	5: nop
	6: nop
	nop
	nop
	
	'''
		
	print 'setcr s0, 29'
	for x in range(8):
		print '\t\tnop'

	print '1:\tgoto 1b'
	
print '.align 64'
print 'data:'
for x in range(4096):
	if (x & 7) == 0:
		print '\n.long',
	else:
		print ',',

	print hex(random.randint(0, 0xffffffff)),
	


