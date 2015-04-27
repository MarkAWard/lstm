#!/bin/bash
module load torch-deps/7
/home/maw627/torch/install/bin/th main.lua -mode evaluate -format char -model char_baseline.net -vocab_size 50
