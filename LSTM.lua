------------------------------------------------------------------------
--[[ LSTM ]]--
-- Long Short Term Memory architecture.
-- Ref. A.: http://arxiv.org/pdf/1303.5778v1 (blueprint for this module)
-- B. http://web.eecs.utk.edu/~itamar/courses/ECE-692/Bobby_paper1.pdf
-- C. http://arxiv.org/pdf/1503.04069v1.pdf
-- D. https://github.com/wojzaremba/lstm
-- Expects 1D or 2D input.
-- The first input in sequence uses zero value for cell and hidden state
------------------------------------------------------------------------
local LSTM, parent
if nn.LSTM then -- prevent name conflicts with nnx
   LSTM, parent = nn.LSTM, nn.AbstractRecurrent
else
   LSTM, parent = torch.class('nn.LSTM', 'nn.AbstractRecurrent')
end

function LSTM:__init(inputSize, outputSize, rho)
   parent.__init(self, rho or 9999)
   self.inputSize = inputSize
   self.outputSize = outputSize   
   -- build the model
   self.recurrentModule = self:buildModel()
   -- make it work with nn.Container
   self.modules[1] = self.recurrentModule
   self.sharedClones[1] = self.recurrentModule 
   
   -- for output(0), cell(0) and gradCell(T)
   self.zeroTensor = torch.Tensor() 
   
   self.cells = {}
   self.gradCells = {}
end

-------------------------- factory methods -----------------------------
function LSTM:buildGate()
   -- Note : gate expects an input table : {input, output(t-1), cell(t-1)}
   local gate = nn.Sequential()
   local input2gate = nn.Linear(self.inputSize, self.outputSize)
   local output2gate = nn.Linear(self.outputSize, self.outputSize)
   local cell2gate = nn.CMul(self.outputSize) -- diagonal cell to gate weight matrix
   --output2gate:noBias() --TODO
   local para = nn.ParallelTable()
   para:add(input2gate):add(output2gate):add(cell2gate)
   gate:add(para)
   gate:add(nn.CAddTable())
   gate:add(nn.Sigmoid())
   return gate
end

function LSTM:buildInputGate()
   self.inputGate = self:buildGate()
   return self.inputGate
end

function LSTM:buildForgetGate()
   self.forgetGate = self:buildGate()
   return self.forgetGate
end

function LSTM:buildHidden()
   local hidden = nn.Sequential()
   local input2hidden = nn.Linear(self.inputSize, self.outputSize)
   local output2hidden = nn.Linear(self.outputSize, self.outputSize) 
   local para = nn.ParallelTable()
   --output2hidden:noBias()
   para:add(input2hidden):add(output2hidden)
   -- input is {input, output(t-1), cell(t-1)}, but we only need {input, output(t-1)}
   local concat = nn.ConcatTable()
   concat:add(nn.SelectTable(1)):add(nn.SelectTable(2))
   hidden:add(concat)
   hidden:add(para)
   hidden:add(nn.CAddTable())
   self.hiddenLayer = hidden
   return hidden
end

function LSTM:buildCell()
   -- build
   self.inputGate = self:buildInputGate() 
   self.forgetGate = self:buildForgetGate()
   self.hiddenLayer = self:buildHidden()
   -- forget = forgetGate{input, output(t-1), cell(t-1)} * cell(t-1)
   local forget = nn.Sequential()
   local concat = nn.ConcatTable()
   concat:add(self.forgetGate):add(nn.SelectTable(3))
   forget:add(concat)
   forget:add(nn.CMulTable())
   -- input = inputGate{input, output(t-1), cell(t-1)} * hiddenLayer{input, output(t-1), cell(t-1)}
   local input = nn.Sequential()
   local concat2 = nn.ConcatTable()
   concat2:add(self.inputGate):add(self.hiddenLayer)
   input:add(concat2)
   input:add(nn.CMulTable())
   -- cell(t) = forget + input
   local cell = nn.Sequential()
   local concat3 = nn.ConcatTable()
   concat3:add(forget):add(input)
   cell:add(concat3)
   cell:add(nn.CAddTable())
   self.cellLayer = cell
   return cell
end   
   
function LSTM:buildOutputGate()
   self.outputGate = self:buildGate()
   return self.outputGate
end

-- cell(t) = cellLayer{input, output(t-1), cell(t-1)}
-- output(t) = outputGate{input, output(t-1), cell(t)}*tanh(cell(t))
-- output of Model is table : {output(t), cell(t)} 
function LSTM:buildModel()
   -- build components
   self.cellLayer = self:buildCell()
   self.outputGate = self:buildOutputGate()
   -- assemble
   local concat = nn.ConcatTable()
   local concat2 = nn.ConcatTable()
   concat2:add(nn.SelectTable(1)):add(nn.SelectTable(2))
   concat:add(concat2):add(self.cellLayer)
   local model = nn.Sequential()
   model:add(concat)
   -- output of concat is {{input, output}, cell(t)}, 
   -- so flatten to {input, output, cell(t)}
   model:add(nn.FlattenTable())
   local cellAct = nn.Sequential()
   cellAct:add(nn.SelectTable(3))
   cellAct:add(nn.Tanh())
   local concat3 = nn.ConcatTable()
   concat3:add(self.outputGate):add(cellAct)
   local output = nn.Sequential()
   output:add(concat3)
   output:add(nn.CMulTable())
   -- we want the model to output : {output(t), cell(t)}
   local concat4 = nn.ConcatTable()
   concat4:add(output):add(nn.SelectTable(3))
   model:add(concat4)
   return model
end

------------------------- forward backward -----------------------------
function LSTM:updateOutput(input)
   local prevOutput, prevCell
   if self.step == 1 then
      prevOutput = self.zeroTensor
      prevCell = self.zeroTensor
      if input:dim() == 2 then
         self.zeroTensor:resize(input:size(1), self.outputSize):zero()
      else
         self.zeroTensor:resize(self.outputSize):zero()
      end
      self.outputs[0] = self.zeroTensor
      self.cells[0] = self.zeroTensor
   else
      -- previous output and cell of this module
      prevOutput = self.output
      prevCell = self.cell
   end
      
   -- output(t), cell(t) = lstm{input(t), output(t-1), cell(t-1)}
   local output, cell
   if self.train ~= false then
      self:recycle()
      local recurrentModule = self:getStepModule(self.step)
      -- the actual forward propagation
      output, cell = unpack(recurrentModule:updateOutput{input, prevOutput, prevCell})
   else
      output, cell = unpack(self.recurrentModule:updateOutput{input, prevOutput, prevCell})
   end
   
   if self.train ~= false then
      local input_ = self.inputs[self.step]
      self.inputs[self.step] = self.copyInputs 
         and rnn.recursiveCopy(input_, input) 
         or rnn.recursiveSet(input_, input)     
   end
   
   self.outputs[self.step] = output
   self.cells[self.step] = cell
   
   self.output = output
   self.cell = cell
   
   self.step = self.step + 1
   self.gradParametersAccumulated = false
   -- note that we don't return the cell, just the output
   return self.output
end

function LSTM:backwardThroughTime()
   assert(self.step > 1, "expecting at least one updateOutput")
   self.gradInputs = {} -- used by Sequencer, Repeater
   local rho = math.min(self.rho, self.step-1)
   local stop = self.step - rho
   if self.fastBackward then
      local gradInput, gradPrevOutput, gradCell
      for step=self.step-1,math.max(stop,1),-1 do
         -- set the output/gradOutput states of current Module
         local recurrentModule = self:getStepModule(step)
         
         -- backward propagate through this step
         local gradOutput = self.gradOutputs[step] 
         if gradPrevOutput then
            rnn.recursiveAdd(gradOutput, gradPrevOutput)    
         end
         
         self.gradCells[step] = gradCell
         local scale = self.scales[step]/rho

         local inputTable = {self.inputs[step], self.outputs[step-1], self.cells[step-1]}
         local gradInputTable = recurrentModule:backward(inputTable, {gradOutput, gradCell}, scale)
         gradInput, gradPrevOutput, gradCell = unpack(gradInputTable)
         table.insert(self.gradInputs, 1, gradInput)
      end
      return gradInput
   else
      local gradInput = self:updateGradInputThroughTime()
      self:accGradParametersThroughTime()
      return gradInput
   end
end

function LSTM:updateGradInputThroughTime()
   assert(self.step > 1, "expecting at least one updateOutput")
   self.gradInputs = {}
   local gradInput, gradPrevOutput
   local gradCell = self.zeroTensor
   local rho = math.min(self.rho, self.step-1)
   local stop = self.step - rho
   for step=self.step-1,math.max(stop,1),-1 do
      -- set the output/gradOutput states of current Module
      local recurrentModule = self:getStepModule(step)
      
      -- backward propagate through this step
      local gradOutput = self.gradOutputs[step]
      if gradPrevOutput then
         rnn.recursiveAdd(gradOutput, gradPrevOutput) 
      end
      
      self.gradCells[step] = gradCell
      local scale = self.scales[step]/rho
      local inputTable = {self.inputs[step], self.outputs[step-1], self.cells[step-1]}
      local gradInputTable = recurrentModule:updateGradInput(inputTable, {gradOutput, gradCell}, scale)
      gradInput, gradPrevOutput, gradCell = unpack(gradInputTable)
      table.insert(self.gradInputs, 1, gradInput)
   end
   
   return gradInput
end

function LSTM:accGradParametersThroughTime()
   local rho = math.min(self.rho, self.step-1)
   local stop = self.step - rho
   for step=self.step-1,math.max(stop,1),-1 do
      -- set the output/gradOutput states of current Module
      local recurrentModule = self:getStepModule(step)
      
      -- backward propagate through this step
      local scale = self.scales[step]/rho
      local inputTable = {self.inputs[step], self.outputs[step-1], self.cells[step-1]}
      local gradOutputTable = {self.gradOutputs[step], self.gradCells[step]}
      recurrentModule:accGradParameters(inputTable, gradOutputTable, scale)
   end
   
   self.gradParametersAccumulated = true
   return gradInput
end

function LSTM:accUpdateGradParametersThroughTime(lr)
   local rho = math.min(self.rho, self.step-1)
   local stop = self.step - rho
   for step=self.step-1,math.max(stop,1),-1 do
      -- set the output/gradOutput states of current Module
      local recurrentModule = self:getStepModule(step)
      
      -- backward propagate through this step
      local scale = self.scales[step]/rho
      local inputTable = {self.inputs[step], self.outputs[step-1], self.cells[step]}
      local gradOutputTable = {self.gradOutputs[step], self.gradCells[step]}
      recurrentModule:accUpdateGradParameters(inputTable, gradOutputTable, lr*scale)
   end
   
   return gradInput
end

function LSTM:sharedType(type, castmap)
   local modules = self.modules
   self.modules = {}
   for i,modules in ipairs{modules, self.sharedClones} do
      for j, module in pairs(modules) do
         table.insert(self.modules, module)
      end
   end
   parent.sharedType(self, type, castmap)
   self.modules = modules
   return self
end
