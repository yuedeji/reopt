	.text
	.file	"__toread_needs_stdio_exit_402f4f.ll"
	.globl	F402f4f
	.align	16, 0x90
	.type	F402f4f,@function
F402f4f:                                # @F402f4f
	.cfi_startproc
# BB#0:                                 # %entry
	pushq	%rbp
.Ltmp0:
	.cfi_def_cfa_offset 16
.Ltmp1:
	.cfi_offset %rbp, -16
	movq	%rsp, %rbp
.Ltmp2:
	.cfi_def_cfa_register %rbp
	movd	%xmm0, %rax
	pshufd	$78, %xmm0, %xmm0       # xmm0 = xmm0[2,3,0,1]
	movd	%xmm0, %rcx
	movd	%rax, %xmm0
	movd	%rcx, %xmm1
	punpcklqdq	%xmm1, %xmm0    # xmm0 = xmm0[0],xmm1[0]
	callq	F402eb4
	movq	%rbp, %rsp
	popq	%rbp
	retq
.Ltmp3:
	.size	F402f4f, .Ltmp3-F402f4f
	.cfi_endproc


	.section	".note.GNU-stack","",@progbits
