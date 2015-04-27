#!/bin/bash
module load torch-deps/7
/scratch/ez466/torch/install/bin/./th main.lua -mode evaluate -format char -model char_baseline.net -vocab_size 50
