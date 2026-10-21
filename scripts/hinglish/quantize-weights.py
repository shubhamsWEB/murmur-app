#!/usr/bin/env python3
"""A Hinglish model part (Apex's encoder or decoder) with its MatMul weights in 8 bits, block by block (ONNX Runtime's
MatMulNBits, which the ONNX Runtime in sherpa-onnx 1.13.8, 1.28.2, runs), as the Mac app's 6-bit WhisperKit model has
its weights; the arithmetic stays in float32 (accuracy level 1). Any 8-bit arithmetic changes what this model writes,
and differently on different processors (with and without the int8 dot-product instructions): sherpa-onnx's own int8
(quantize.py: dynamic) repeated words ("Haan haan haan haan haan" for "Haan haan, dekhen."), per tensor or per
channel; 8-bit products a block at a time were word for word on one processor and repeated words on another. Weights
alone, rounded the same everywhere, give the same words on every processor.

    quantize-weights.py <model.onnx> <model.int8.onnx> [--bits 8] [--block 128]
"""
import argparse

import onnx
from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer

parser = argparse.ArgumentParser()
parser.add_argument("model")
parser.add_argument("out")
parser.add_argument("--bits", type=int, default=8)
parser.add_argument("--block", type=int, default=128)
args = parser.parse_args()

model = onnx.load(args.model)   # with its external weights
quantizer = MatMulNBitsQuantizer(model, bits=args.bits, block_size=args.block, is_symmetric=True, accuracy_level=1)
quantizer.process()
quantized = quantizer.model.model
del model
onnx.save(quantized, args.out)
nbits = sum(1 for node in quantized.graph.node if node.op_type == "MatMulNBits")
print(f"{args.out}: done ({args.bits}-bit weights in blocks of {args.block}, {nbits} MatMuls)")
