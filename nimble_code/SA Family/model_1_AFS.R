# library(splines)
library(fields)
library(splines2)
library(nimble)
library(vegan)
library(geosphere)

rm(list = ls())

#----------------------------------------------------------------
# load in and parse data
#----------------------------------------------------------------

dat_all = read.csv('/home/harold/Code/spGDMM-code/data/sa_family_data.csv')

# Parse data into location, environmental variables, and cover/presence data

location_mat = dat_all[,1:3] 
envr_use = dat_all[,c(4,5,8,9,10,11,12)] 
species_mat = dat_all[,-(1:12)] 

# save number of sites

ns = nrow(location_mat)

#----------------------------------------------------------------
# Calculate Bray-Curtis dissimilarity -- see proportion of 0's and 1's
#----------------------------------------------------------------

dist_use = as.matrix(vegdist(species_mat,"bray"))

Z = dist_use[upper.tri(dist_use)]

# index for those which are exactly one

Z_is_one = which(Z == 1)
Z_is_not_one = which(Z != 1)

# get counts

n1 = length(Z_is_one)
N = length(Z)

mean(Z == 0)
mean(Z == 1)

#----------------------------------------------------------------
# Define covariates that will be warped
#----------------------------------------------------------------

# Calculate geographical distance in km

dist_mat = distm(cbind(location_mat$longitude,location_mat$latitude))/1e3
vec_distance = dist_mat[upper.tri(dist_mat)]

# Define X to be environmental variables or a subset of them.

# How many knots do you want? What is the degree of the spline?
# Remember that in the specification, of the iSpline that the degree is
# one higher that what you say. Integration of m-spline adds one degree.

X = envr_use[,c("gmap","RFL_CONC","Elevation30m","HeatLoadIndex30m","tmean13c",
                "SoilConductivitymSm","SoilTotalNPercent")]
deg = 3
knots = 2
df_use = deg + knots

formula_use = as.formula(paste("~ 0 +",paste(
  paste("iSpline(`",colnames(X),"`,degree=",deg - 1 ,",df = ",df_use, 
        " ,intercept = TRUE)",sep = ""),collapse = "+")))

# combine distance and environmental I-spline basange(X_poly.shape[1]-2)es

I_spline_bases = model.matrix(formula_use,data = X)

X_GDM = cbind(sapply(1:ncol(I_spline_bases),function(i){
  
  dist_temp = rdist(I_spline_bases[,i])
  vec_dist = dist_temp[upper.tri(dist_temp)]
  vec_dist
  
}),
iSpline(vec_distance,degree = deg -1,
        df = df_use,intercept = TRUE)
)

p = ncol(X_GDM)


colnames(X_GDM) = c(
  paste(rep(colnames(X),each = df_use ),"I",rep(1:df_use,times = ncol(X)),sep = ""),
  paste("dist","I",1:df_use,sep = "")
)

### Associate each dissimilarity with two sites (row and col index)

tmp = matrix(rep(1:nrow(dist_use),each = nrow(dist_use)),nrow = nrow(dist_use))
col_ind = tmp[upper.tri(tmp)]
tmp = matrix(rep(1:nrow(dist_use),times = nrow(dist_use)),nrow = nrow(dist_use))
row_ind = tmp[upper.tri(tmp)]

#------------------------------------------------------------------------
# Get Initial values for modeling fitting
#------------------------------------------------------------------------

lm_mod= lm(log(Z) ~ X_GDM)

print("Starting BFGS optimisation")

lm_out = optim(c(.3, ifelse(coef(lm_mod)[-1]> 0,log(coef(lm_mod)[-1]), -10),rnorm(ns)) ,function(par){
  sum((log(Z) - par[1] - X_GDM %*% exp(par[2:(p + 1)]))^2)
},method = "BFGS")

print("Finished fitting linear model and BFGS")

#------------------------------------------------------------------------
# Fix spatial range parameter (rho = 1 / phi)
#------------------------------------------------------------------------
rho_fix = max(dist_mat)/10
R_spat = exp(-dist_mat/rho_fix)
chol_R = t(chol(R_spat))
R_inv = solve(R_spat)

#------------------------------------------------------------------------
# Define design matrix for polynomial log-variance
#------------------------------------------------------------------------

X_sigma = cbind(1,poly(vec_distance,degree = 3))
p_sigma = ncol(X_sigma)

#------------------------------------------------------------------------
# Source nimble models -- Models 1-9 match those in paper
#------------------------------------------------------------------------

source("/home/harold/Code/spGDMM-code/nimble_code/nimble_models.R")

# create constants for nimble model

constants <- list(n = N, p = p, x = X_GDM,n_loc = ns,
                  p_sigma = p_sigma,X_sigma = X_sigma,R_inv = R_inv, 
                  zeros = rep(0, ns),row_ind = row_ind, col_ind = col_ind)

# create data for nimble model

data <- list(log_V = ifelse(Z == 1,NA, log(Z)),
             censored = 1*(Z == 1),
             c = rep(0,constants$n))

# create initial values for nimble model -- this will change depending on model

inits <- list(beta_0 = lm_out$par[1],
              log_beta = lm_out$par[2:(p+1)],
              sig2_psi = 1,
              beta_sigma = c(-5,-20,12,2),
              psi = lm_out$par[-(1:(p+1))])

#### "nimble_code1" is model 1 in paper. Change to what you want in nimble_models.R.
suppressWarnings({
  model <- nimbleModel(nimble_code1, constants = constants, data = data, inits = inits)

  mcmcConf <- configureMCMC(model)

# Remove default samplers in order to define our own.

  # Block sampler for beta_0, log(\beta_{jk}), and \beta_{\sigma}
  # MCMC may work better including psi in this blocking
  # Some models (1,4,7) won't have beta_sigma
  mcmcConf$removeSamplers(c("beta_0",'log_beta','sigma2'))

# Here we can select the type of sampler we want to use e.g. RW, AF, Gibbs, Metropolis-hastings
# Block samplers sample multiple parameters simultaneously, improves efficiency part when parameters are correlated
# Adaptive slice sampler used here

  # mcmcConf$addSampler(target = c("beta_0",'log_beta',"sigma2"), type = 'RW_block')
  mcmcConf$addSampler(target = c("beta_0",'log_beta','sigma2'), 
                      type = 'AF_slice')
})
# May need to change depending on model
# For example, models 1, 4, and 7 will have "sigma2" instead of "beta_sigma"
# For example, models 1, 2, and 3 will not have "psi"
### Here, beta represents beta* discussed in the supplement, the product of alpha_k and \beta_{k,j}

# These parameters will be tracked and stored
mcmcConf$addMonitors(c('beta_0','beta','sigma2'))

# WAIC is a model comparison and validation metric in Bayesian analysis
# Evalutes fit and penalises complexity
# Lower score indicates better trade-off between fit and complexity. Useful to compare models.
mcmcConf$enableWAIC = TRUE

# Build the MCMC object with config
codeMCMC <- buildMCMC(mcmcConf)

# Compile the MCMC sampler and model to C in order to improve speed
Cmodel = compileNimble(codeMCMC,model)

##### Run a super long MCMC
##### thin so that we get 10,000 posterior samples -- saves memory

# No iterations
n_tot = 10e3

# Burn-in iterations
n_burn = 5e3

# Number of posterior samples
n_post = n_tot - n_burn


# You may get some warnings because we didn't initialize log_V where Z = 1.
# Thin sets how frequently to record samples
st = proc.time()
post_samples <- runMCMC(Cmodel$codeMCMC,niter = n_tot,nburnin = n_burn,
                        thin = 1,WAIC = TRUE)
elapsed = proc.time() - st

saveRDS(data.frame(model = 1,
                   time_mins = elapsed[1]/60,
                   WAIC = post_samples$WAIC$WAIC,
                   p_WAIC =  post_samples$WAIC$pWAIC,
                   lppd = post_samples$WAIC$lppd
                   ),"mod1_sa.rds")

saveRDS(post_samples, "mod1_FA_post_samples.rds")

# rm(list=ls())

# ##### A few trace plot
# plot(post_samples$samples[,"beta_0"],type= "l")
# plot(post_samples$samples[,"log_beta[9]"],type= "l")
# plot(post_samples$samples[,"beta[9]"],type= "l")
# 
# plot(post_samples$samples[,"beta_sigma[2]"],type= "l")
# plot(post_samples$samples[,"psi[2]"],type= "l")
# plot(post_samples$samples[,"sig2_psi"],type= "l")