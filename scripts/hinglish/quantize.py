#!/usr/bin/env python3
"""The int8 models sherpa-onnx runs, from the export's float32 ones, one at a time in a process of its own (the
encoder is 2.6 GB: quantised in the export's own process, beside the model, it needs more memory than a runner has).
Exactly what sherpa-onnx's export script does at its end: dynamic quantisation of the MatMuls, weights in QInt8.

    quantize.py <model.onnx> <model.int8.onnx>
"""
import sys

from onnxruntime.quantization import QuantType, quantize_dynamic

if len(sys.argv) != 3:
    sys.exit(__doc__)
quantize_dynamic(model_input=sys.argv[1], model_output=sys.argv[2], op_types_to_quantize=["MatMul"],
                 weight_type=QuantType.QInt8)
print(f"{sys.argv[2]}: done")
