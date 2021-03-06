--
----  Copyright (c) 2014, Facebook, Inc.
----  All rights reserved.
----
----  This source code is licensed under the Apache 2 license found in the
----  LICENSE file in the root directory of this source tree. 
----
use_cpu = false
ok,cunn = pcall(require, 'fbcunn')
if not ok then
  ok,cunn = pcall(require,'cunn')
  if ok then
    print("warning: fbcunn not found. Falling back to cunn") 
    LookupTable = nn.LookupTable
  else
    print("Could not find cunn or fbcunn. Falling back to CPU")
    ok, nn = pcall(require, 'nn')
    if not ok then
      print("Could not find nn. Cannot continue, exiting")
      os.exit()
    else
      use_cpu = true
      LookupTable = nn.LookupTable
    end
  end
else
    deviceParams = cutorch.getDeviceProperties(1)
    cudaComputeCapability = deviceParams.major + deviceParams.minor/10
    LookupTable = nn.LookupTable
end
require('nngraph')
require('base')
ptb = require('data')
stringx = require('pl.stringx')
require 'io'

cmd = torch.CmdLine()
cmd:text()
cmd:text('Options:')
cmd:text()
cmd:option('-mode', 'train', 'train|test|query|evaluate')
cmd:option('-format', 'word', 'word|char')
cmd:option('-model', 'baseline.net')
cmd:text()
cmd:option('-vocab_size', 10000)
cmd:option('-seq_length', 20)
cmd:option('-rnn_size', 200)
cmd:text()
cmd:option('-layers', 2)
cmd:option('-dropout', 0)
cmd:option('-init_weight', 0.1)
cmd:text()
cmd:option('-batch_size', 20)
cmd:option('-lr', 1)
cmd:option('-decay', 2)
cmd:text()
cmd:option('-max_epoch', 4)
cmd:option('-max_max_epoch', 13)
cmd:option('-max_grad_norm', 5)
cmd:text()
cmd:option('-gpu_device', 1)
cmd:text()

params = cmd:parse(arg or {})

-- Train 1 day and gives 82 perplexity.
--[[
local params = {batch_size=20,
                seq_length=35,
                layers=2,
                decay=1.15,
                rnn_size=1500,
                dropout=0.65,
                init_weight=0.04,
                lr=1,
                vocab_size=10000,
                max_epoch=14,
                max_max_epoch=55,
                max_grad_norm=10}
               ]]--

-- Trains 1h and gives test 115 perplexity.
--[[
params = {batch_size=20,
                seq_length=20,
                layers=3,
                decay=2,
                rnn_size=200,
                dropout=.4,
                init_weight=0.1,
                lr=1,
                vocab_size=10000,
                max_epoch=4,
                max_max_epoch=13,
                max_grad_norm=5,
                gpu_device=2}
]]--

-- alter for use with cpu
function transfer_data(x)
  if use_cpu then return x:float()
  else return x:cuda() end
end

function lstm(i, prev_c, prev_h)
  local function new_input_sum()
    local i2h            = nn.Linear(params.rnn_size, params.rnn_size)
    local h2h            = nn.Linear(params.rnn_size, params.rnn_size)
    return nn.CAddTable()({i2h(i), h2h(prev_h)})
  end
  local in_gate          = nn.Sigmoid()(new_input_sum())
  local forget_gate      = nn.Sigmoid()(new_input_sum())
  local in_gate2         = nn.Tanh()(new_input_sum())
  local next_c           = nn.CAddTable()({
    nn.CMulTable()({forget_gate, prev_c}),
    nn.CMulTable()({in_gate,     in_gate2})
  })
  local out_gate         = nn.Sigmoid()(new_input_sum())
  local next_h           = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})
  return next_c, next_h
end

function create_network()
  if params.mode == 'train' then
    local x                = nn.Identity()()
    local y                = nn.Identity()()
    local prev_s           = nn.Identity()()
    local i                = {[0] = LookupTable(params.vocab_size,
                                                      params.rnn_size)(x)}
    local next_s           = {}
    local split         = {prev_s:split(2 * params.layers)}
    for layer_idx = 1, params.layers do
      local prev_c         = split[2 * layer_idx - 1]
      local prev_h         = split[2 * layer_idx]
      local dropped        = nn.Dropout(params.dropout)(i[layer_idx - 1])
      local next_c, next_h = lstm(dropped, prev_c, prev_h)
      table.insert(next_s, next_c)
      table.insert(next_s, next_h)
      i[layer_idx] = next_h
    end
    local h2y              = nn.Linear(params.rnn_size, params.vocab_size)
    local dropped          = nn.Dropout(params.dropout)(i[params.layers])
    local pred             = nn.LogSoftMax()(h2y(dropped))
    local err              = nn.ClassNLLCriterion()({pred, y})
    -- also return the log probs from the model
    local module           = nn.gModule({x, y, prev_s},
                                        {err, nn.Identity()(next_s), pred})
    module:getParameters():uniform(-params.init_weight, params.init_weight)
    return transfer_data(module)
  else
    -- load in a core_network if we are not traininng
    return torch.load(params.model)
  end
end

model = {}

function setup()
  print("Creating a RNN LSTM network.")
  local core_network = create_network()
  paramx, paramdx = core_network:getParameters()
  model.s = {}
  model.ds = {}
  model.start_s = {}
  for j = 0, params.seq_length do
    model.s[j] = {}
    for d = 1, 2 * params.layers do
      model.s[j][d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
    end
  end
  for d = 1, 2 * params.layers do
    model.start_s[d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
    model.ds[d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
  end
  model.core_network = core_network
  model.rnns = g_cloneManyTimes(core_network, params.seq_length)
  model.norm_dw = 0
  model.err = transfer_data(torch.zeros(params.seq_length))
end

function reset_state(state)
  state.pos = 1
  if model ~= nil and model.start_s ~= nil then
    for d = 1, 2 * params.layers do
      model.start_s[d]:zero()
    end
  end
end

function reset_ds()
  for d = 1, #model.ds do
    model.ds[d]:zero()
  end
end

function fp(state)
  g_replace_table(model.s[0], model.start_s)
  if state.pos + params.seq_length > state.data:size(1) then
    reset_state(state)
  end
  for i = 1, params.seq_length do
    local x = state.data[state.pos]
    local y = state.data[state.pos + 1]
    local s = model.s[i - 1]
    -- three outputs, dont care about the third here
    model.err[i], model.s[i], _ = unpack(model.rnns[i]:forward({x, y, s}))
    state.pos = state.pos + 1
  end
  g_replace_table(model.start_s, model.s[params.seq_length])
  return model.err:mean()
end

function bp(state)
  paramdx:zero()
  reset_ds()
  local pred_zeros = transfer_data(torch.zeros(params.batch_size, params.vocab_size))
  for i = params.seq_length, 1, -1 do
    state.pos = state.pos - 1
    local x = state.data[state.pos]
    local y = state.data[state.pos + 1]
    local s = model.s[i - 1]
    local derr = transfer_data(torch.ones(1))
    -- add zeros for gradient wrt the probs 
    local tmp = model.rnns[i]:backward({x, y, s},
                                       {derr, model.ds, pred_zeros})[3]
    g_replace_table(model.ds, tmp)
    if not use_cpu then
      cutorch.synchronize()
    end
  end
  state.pos = state.pos + params.seq_length
  model.norm_dw = paramdx:norm()
  if model.norm_dw > params.max_grad_norm then
    local shrink_factor = params.max_grad_norm / model.norm_dw
    paramdx:mul(shrink_factor)
  end
  paramx:add(paramdx:mul(-params.lr))
end

function run_valid()
  reset_state(state_valid)
  g_disable_dropout(model.rnns)
  local len = (state_valid.data:size(1) - 1) / (params.seq_length)
  local perp = 0
  for i = 1, len do
    perp = perp + fp(state_valid)
  end
  if params.format == 'char' then
    mult = 5.6
  else
    mult = 1.0
  end
  print("Validation set perplexity : " .. g_f3(torch.exp( mult * (perp / len) )))
  g_enable_dropout(model.rnns)
end

function run_test()
  reset_state(state_test)
  g_disable_dropout(model.rnns)
  local perp = 0
  local len = state_test.data:size(1)
  g_replace_table(model.s[0], model.start_s)
  for i = 1, (len - 1) do
    local x = state_test.data[i]
    local y = state_test.data[i + 1]
    local s = model.s[i - 1]
    -- three outputs, dont care about the third here
    perp_tmp, model.s[1], _ = unpack(model.rnns[1]:forward({x, y, model.s[0]}))
    perp = perp + perp_tmp[1]
    g_replace_table(model.s[0], model.s[1])
  end
  print("Test set perplexity : " .. g_f3(torch.exp(perp / (len - 1) )))
  g_enable_dropout(model.rnns)
end

-- complete a sequence of words
function complete_sequence(state)
  reset_state(state)
  g_replace_table(model.s[0], model.start_s)
  local pred = transfer_data(torch.zeros(params.batch_size, params.vocab_size))
  for i = 1, state.total_length-1 do
    local x = state.data[i]
    local y = state.data[i+1]
    err, model.s[1], pred = unpack(model.rnns[1]:forward({x, y, model.s[0]}))
    g_replace_table(model.s[0], model.s[1])
    if i >= state.n_given then
      p = pred[1]
      state.data[i+1]:fill(torch.multinomial(torch.exp(p:float()),1)[1])
    end
  end
end

-- read in a line and convert it to the state that the above function wants
function convert_input()
  local line = io.read("*line")
  if line == nil then error({code="EOF"}) end
  line = stringx.split(line)
  if tonumber(line[1]) == nil then error({code="init"}) end
  local n_predict = tonumber(line[1])
  local n_given = #line - 1
  state_query = {}
  state_query.line = line
  state_query.total_length = n_predict + n_given
  state_query.n_given = n_given
  state_query.data = transfer_data(torch.ones(state_query.total_length, params.batch_size))
  for i = 2, #line do
    local idx = ptb.lookup(line[i])
    state_query.data[i-1]:fill(idx)
  end
  return state_query
end

-- IO loop for sentence completion
function query_sentences()
  g_disable_dropout(model.rnns)
  while true do
    print("Query: len word1 word2 etc")
    local ok, line = pcall(convert_input)
    if not ok then
      if line.code == "EOF" then
        break -- end loop
      elseif line.code == "init" then
        print("Start with a number")
      else
        print(line.line)
        print("Failed, try again")
      end
    else
      complete_sequence(line)
      for i = 1, line.total_length do 
        if i <= line.n_given then io.write(line.line[i+1] .. ' ') 
        else io.write(ptb.inverse_map[line.data[i][1]] .. ' ')
        end
      end
      io.write('\n\n')
    end
  end
end

-- predict the next character in the sequence
-- never reset the state variables
function next_char(state)
  -- if state.pos > params.seq_length then
  --   reset_state(state)
  --   g_replace_table(model.s[0], model.start_s)
  local pred = transfer_data(torch.zeros(params.batch_size, params.vocab_size))
  local x = state.data[1]
  local y = state.data[2]
  err, model.s[1], pred = unpack(model.rnns[1]:forward({x, y, model.s[0]}))
  g_replace_table(model.s[0], model.s[1])
  return pred[1]
end

-- read in a line / a single character
function readline()
  local line = io.read("*line")
  if line == nil then error({code="EOF"}) end
  line = stringx.split(line)
  if #line > 1 then error({code="char"}) end
  if ptb.vocab_map[line[1]] == nil then error({code="vocab"}) end
  return line
end

-- IO loop for predicting the next character
function evaluate_chars()
  g_disable_dropout(model.rnns)
  state_chars = {}
  state_chars.data = transfer_data(torch.ones(2, params.batch_size))
  state_chars.pos = 1
  probs = transfer_data(torch.zeros(params.vocab_size))
  io.write("OK GO\n")
  while true do
    io.flush()
    local ok, line = pcall(readline)
    if not ok then
      if line.code == "EOF" then
        break -- end loop
      elseif line.code == "char" then
        print("One character at a time please")
      elseif line.code == "vocab" then
        print("Character is not in the vocabulary")
      else
        print(line)
        print("Failed, try again")
      end
    else
      idx = ptb.vocab_map[line[1]]
      state_chars.data[1]:fill(idx)
      probs = next_char(state_chars)
--      probs = normalize(probs)
      for i = 1, params.vocab_size do 
        io.write(probs[i] .. ' ')
      end
      io.write('\n')
    end
  end 
end

function normalize(x)
  return torch.log( torch.exp(x) / torch.exp(x):sum() )
end

if not use_cpu then
  g_init_gpu(params.gpu_device)
end
setup()

if params.mode == 'query' then

   tmp = ptb.traindataset(params.batch_size)
   tmp = nil
   query_sentences()

elseif params.mode == 'evaluate' then

  tmp = ptb.traindataset(params.batch_size, true)
  tmp = nil
  evaluate_chars()

elseif params.mode == 'train' then

  print("Network parameters:")
  print(params)
  if params.format == 'char' then char = true end
  state_train = {data=transfer_data(ptb.traindataset(params.batch_size, char))}
  state_valid =  {data=transfer_data(ptb.validdataset(params.batch_size, char))}
  if params.format == 'word' then
    state_test =  {data=transfer_data(ptb.testdataset(params.batch_size))}
  else
    state_test = {}
  end
  local states = {state_train, state_valid, state_test}
  for _, state in pairs(states) do
   reset_state(state)
  end
  step = 0
  epoch = 0
  total_cases = 0
  mult = 1.0
  if params.format == 'char' then mult = 5.6 end
  words_per_step = params.seq_length * params.batch_size
  epoch_size = torch.floor(state_train.data:size(1) / params.seq_length)

  print("Starting training.")
  beginning_time = torch.tic()
  start_time = torch.tic()

  while epoch < params.max_max_epoch do
    perp = fp(state_train)
    if perps == nil then
      perps = torch.zeros(epoch_size):add(perp)
    end
    perps[step % epoch_size + 1] = perp
    step = step + 1
    bp(state_train)
    total_cases = total_cases + params.seq_length * params.batch_size
    epoch = step / epoch_size
    if step % torch.round(epoch_size / 10) == 10 then
      wps = torch.floor(total_cases / torch.toc(start_time))
      since_beginning = g_d(torch.toc(beginning_time) / 60)
      print('epoch = ' .. g_f3(epoch) ..
            ', train perp. = ' .. g_f3(torch.exp( mult * perps:mean() )) ..
            ', wps = ' .. wps ..
            ', dw:norm() = ' .. g_f3(model.norm_dw) ..
            ', lr = ' ..  g_f3(params.lr) ..
            ', since beginning = ' .. since_beginning .. ' mins.')
    end
    if step % epoch_size == 0 then
      run_valid()
      torch.save(params.model, model.core_network)
      if epoch > params.max_epoch then
        params.lr = params.lr / params.decay
      end
    end
    if step % 33 == 0 then
      if not use_cpu then 
        cutorch.synchronize()
      end
      collectgarbage()
    end
  end
  if params.format == 'word' then
    run_test()
  end
  print("Training is over.")
  torch.save(params.model, model.core_network)
end
