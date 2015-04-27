require 'nngraph'

x1 = nn.Identity()()
x2 = nn.Identity()()
x3 = nn.Linear(3, 2)()

m1 = nn.CMulTable()({x2, x3})
m2 = nn.CAddTable()({x1, m1})

gmodel = nn.gModule({x1, x2, x3}, {m2})

-- Test model --
params, _ = gmodel:getParameters()
params:ones(params:size())

lin = nn.Linear(3,2)
p, _ = lin:getParameters()
p:ones(p:size())

a = torch.Tensor{-1, -1}
b = torch.Tensor{2, 2}
c = torch.Tensor{1, 1, 1}

out1 = gmodel:forward({a,b,c})
out2 = a + torch.cmul(b, lin:forward(c))

test_equal = torch.eq(out1, out2)
if torch.sum(test_equal) == test_equal:size(1) then
   same = true
else
   same = false
end

if same then
   print("The result is correct!")
else
   print("The result is NOT correct!")
end