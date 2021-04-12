using Statistics
using StatsBase:sample, sample!
using Revise
using EvoTrees
using BenchmarkTools
using CUDA

# prepare a dataset
features = rand(Int(1.25e6), 100)
# features = rand(100, 10)
X = features
Y = rand(size(X, 1))
𝑖 = collect(1:size(X, 1))

# train-eval split
𝑖_sample = sample(𝑖, size(𝑖, 1), replace=false)
train_size = 0.8
𝑖_train = 𝑖_sample[1:floor(Int, train_size * size(𝑖, 1))]
𝑖_eval = 𝑖_sample[floor(Int, train_size * size(𝑖, 1)) + 1:end]

X_train, X_eval = X[𝑖_train, :], X[𝑖_eval, :]
Y_train, Y_eval = Y[𝑖_train], Y[𝑖_eval]


###########################
# Tree CPU
###########################
params_c = EvoTreeRegressor(T=Float32,
    loss=:linear, metric=:none,
    nrounds=100,
    λ=1.0, γ=0.1, η=0.1,
    max_depth=6, min_weight=1.0,
    rowsample=0.5, colsample=0.5, nbins=64);

model_c, cache_c = EvoTrees.init_evotree(params_c, X_train, Y_train);

# initialize from cache
params_c = model_c.params
X_size = size(cache_c.X_bin)

# select random rows and cols
sample!(params_c.rng, cache_c.𝑖_, cache_c.𝑖, replace=false, ordered=true)
sample!(params_c.rng, cache_c.𝑗_, cache_c.𝑗, replace=false, ordered=true)
𝑖 = cache_c.𝑖
𝑗 = cache_c.𝑗
𝑛 = cache_c.𝑛

# build a new tree
# 897.800 μs (6 allocations: 736 bytes)
@time EvoTrees.update_grads!(params_c.loss, cache_c.δ, cache_c.pred_cpu, cache_c.Y_cpu)
# ∑ = vec(sum(cache_c.δ[𝑖,:], dims=1))
# gain = EvoTrees.get_gain(params_c.loss, ∑, params_c.λ)
# assign a root and grow tree
# train_nodes[1] = EvoTrees.TrainNode(UInt32(0), UInt32(1), ∑, gain)
# 69.247 ms (1852 allocations: 38.41 MiB)
@time EvoTrees.grow_tree!(EvoTrees.Tree(params_c.max_depth, model_c.K, params_c.λ), params_c, cache_c.δ, cache_c.hist, cache_c.histL, cache_c.histR, cache_c.gains, cache_c.edges, 𝑖, 𝑗, 𝑛, cache_c.X_bin);
@btime EvoTrees.grow_tree!(EvoTrees.Tree($params_c.max_depth, $model_c.K, $params_c.λ), $params_c, $cache_c.δ, $cache_c.hist, $cache_c.histL, $cache_c.histR, $cache_c.gains, $cache_c.edges, $𝑖, $𝑗, $𝑛, $cache_c.X_bin);
@code_warntype EvoTrees.grow_tree!(EvoTrees.Tree(params_c.max_depth, model_c.K, params_c.λ), params_c, cache_c.δ, cache_c.hist, cache_c.histL, cache_c.histR, cache_c.gains, cache_c.edges, 𝑖, 𝑗, 𝑛, cache_c.X_bin);

push!(model_c.trees, tree)
@btime EvoTrees.predict!(cache_c.pred, tree, cache_c.X)

δ, hist, K, edges, X_bin, histL, histR, gains, nodes = cache_c.δ, cache_c.hist, cache_c.K, cache_c.edges, cache_c.X_bin, cache_c.histL, cache_c.histR, cache_c.gains, cache_c.nodes;

# 9.613 ms (81 allocations: 13.55 KiB)
@time EvoTrees.update_hist!(hist, δ, X_bin, 𝑖, 𝑗, 𝑛)
@btime EvoTrees.update_hist!($hist, $δ, $X_bin, $𝑖, $𝑗, $𝑛)
@code_warntype EvoTrees.update_hist!(hist, δ, X_bin, 𝑖, 𝑗, 𝑛)

j = 1
# 601.685 ns (6 allocations: 192 bytes) * 100 feat ~ 60us
nid = 1:1
EvoTrees.update_gains!(gains, hist, histL, histR, 𝑗, params_c, nid)
@btime EvoTrees.update_gains!($gains, $hist, $histL, $histR, $𝑗, $params_c, $nid)
@code_warntype EvoTrees.update_gains!(gains, hist, histL, histR, 𝑗, params_c, nid)

@time EvoTrees.update_set!(𝑛, 𝑖, X_bin, nodes[:feats], nodes[:cond_bins], params_c.nbins)

###################################################
# GPU
###################################################
params_g = EvoTreeRegressor(T=Float32,
    loss=:linear, metric=:none,
    nrounds=100,
    λ=1.0, γ=0.1, η=0.1,
    max_depth=6, min_weight=1.0,
    rowsample=0.5, colsample=0.5, nbins=64);

model_g, cache_g = EvoTrees.init_evotree_gpu(params_g, X_train, Y_train);

params_g = model_g.params;
X_size = size(cache_g.X_bin);

# select random rows and cols
𝑖 = CuVector(cache_g.𝑖_[sample(params_g.rng, cache_g.𝑖_, ceil(Int, params_g.rowsample * X_size[1]), replace=false, ordered=true)])
𝑗 = CuVector(cache_g.𝑗_[sample(params_g.rng, cache_g.𝑗_, ceil(Int, params_g.colsample * X_size[2]), replace=false, ordered=true)])
𝑛 = cache_g.𝑛
# reset gain to -Inf
# splits.gains .= -Inf

# build a new tree
# 144.600 μs (23 allocations: 896 bytes) - 5-6 X time faster on GPU
@time CUDA.@sync EvoTrees.update_grads_gpu!(params_g.loss, cache_g.δ, cache_g.pred_gpu, cache_g.Y)
@btime CUDA.@sync EvoTrees.update_grads_gpu!($params_g.loss, $cache_g.δ, $cache_g.pred_gpu, $cache_g.Y)
# sum Gradients of each of the K parameters and bring to CPU

# 33.447 ms (6813 allocations: 307.27 KiB)
tree = EvoTrees.TreeGPU(UInt32(params_g.max_depth), model_g.K, params_g.λ)
CUDA.@time EvoTrees.grow_tree_gpu!(tree, params_g, cache_g.δ, cache_g.hist, cache_g.histL, cache_g.histR, cache_g.gains, cache_g.edges, 𝑖, 𝑗, 𝑛, cache_g.X_bin);
@btime EvoTrees.grow_tree_gpu!(EvoTrees.TreeGPU(UInt32($params_g.max_depth), $model_g.K, $params_g.λ), $params_g, $cache_g.δ, $cache_g.hist, $cache_g.histL, $cache_g.histR, $cache_g.gains, $cache_g.edges, $𝑖, $𝑗, $𝑛, $cache_g.X_bin);
@code_warntype EvoTrees.grow_tree_gpu!(EvoTrees.TreeGPU(params_g.max_depth, model_g.K, params_g.λ), params_g, cache_g.δ, cache_g.hist, cache_g.histL, cache_g.histR, cache_g.gains, cache_g.edges, 𝑖, 𝑗, 𝑛, cache_g.X_bin);

push!(model_g.trees, tree);
# 2.736 ms (93 allocations: 13.98 KiB)
@btime CUDA.@sync EvoTrees.predict_gpu!(cache_g.pred_cpu, tree, cache_g.X)
# 1.013 ms (37 allocations: 1.19 KiB)
@btime CUDA.@sync cache_g.pred .= CuArray(cache_g.pred_cpu);

###########################
# Tree GPU
###########################
δ, hist, histL, histR, gains, K, edges, X_bin = cache_g.δ, cache_g.hist, cache_g.histL, cache_g.histR, cache_g.gains, cache_g.K, cache_g.edges, cache_g.X_bin;
T = Float32
S = UInt32
active_id = ones(S, 1)
leaf_count = one(S)
tree_depth = one(S)

# 2.930 ms (24 allocations: 656 bytes)
@time CUDA.@sync EvoTrees.update_hist_gpu!(hist, δ, X_bin, 𝑖, 𝑗, 𝑛, 1, MAX_THREADS=256);
@btime CUDA.@sync EvoTrees.update_hist_gpu!($hist, $δ, $X_bin, $𝑖, $𝑗, $𝑛, 1, MAX_THREADS=256);
hist[3,:,:,1]

depth=1
nid = 2^(depth - 1):2^(depth) - 1
# 97.000 μs (159 allocations: 13.09 KiB)
@time CUDA.@sync EvoTrees.update_gains_gpu!(gains::AbstractArray{T,3}, hist::AbstractArray{T,4}, histL::AbstractArray{T,4}, histR::AbstractArray{T,4}, 𝑗::AbstractVector{S}, params_g, nid, depth);
@btime CUDA.@sync EvoTrees.update_gains_gpu!(gains::AbstractArray{T,3}, hist::AbstractArray{T,4}, histL::AbstractArray{T,4}, histR::AbstractArray{T,4}, 𝑗::AbstractVector{S}, params_g, nid, depth);
gains[:,:,1]

tree = EvoTrees.TreeGPU(UInt32(params_g.max_depth), model_g.K, params_g.λ)
n = 1
best = findmax(view(gains, :,:,n))
if best[2][1] != params_g.nbins && best[1] > -Inf
    tree.gain[n] = best[1]
    tree.feat[n] = best[2][2]
    tree.cond_bin[n] = best[2][1]
    tree.cond_float[n] = edges[tree.feat[n]][tree.cond_bin[n]]
end
tree.split[n] = tree.cond_bin[n] != 0

# 673.900 μs (600 allocations: 29.39 KiB)
@time CUDA.@sync EvoTrees.update_set_gpu!(𝑛, 𝑖, X_bin, tree.feat, tree.cond_bin, params_g.nbins)
@btime CUDA.@sync EvoTrees.update_set_gpu!($𝑛, $𝑖, $X_bin, $tree.feat, $tree.cond_bin, $params_g.nbins)

Int(minimum(𝑛[𝑖]))
Int(maximum(𝑛[𝑖]))
