#' Run the JAGS model
#'
#' \code{run_model} calls JAGS to run the mixing model created by
#' \code{\link{write_JAGS_model}}. This happens when the "RUN MODEL" button is
#' clicked in the GUI.
#'
#' @param run list of MCMC parameters (chainLength, burn, thin, chains, calcDIC).
#'   Alternatively, a user can use a pre-defined parameter set by specifying a
#'   valid string:
#'   \itemize{
#'    \item \code{"test"}: chainLength=1000, burn=500, thin=1, chains=3
#'    \item \code{"very short"}: chainLength=10000, burn=5000, thin=5, chains=3
#'    \item \code{"short"}: chainLength=50000, burn=25000, thin=25, chains=3
#'    \item \code{"normal"}: chainLength=100000, burn=50000, thin=50, chains=3
#'    \item \code{"long"}: chainLength=300000, burn=200000, thin=100, chains=3
#'    \item \code{"very long"}: chainLength=1000000, burn=500000, thin=500, chains=3
#'    \item \code{"extreme"}: chainLength=3000000, burn=1500000, thin=500, chains=3
#'   }
#' @param mix output from \code{\link{load_mix_data}}
#' @param source output from \code{\link{load_source_data}}
#' @param discr output from \code{\link{load_discr_data}}
#' @param model_filename name of JAGS model file (usually should match \code{filename}
#'   input to \code{\link{write_JAGS_model}}).
#' @param alpha.prior Dirichlet prior on p.global (default = 1, uninformative)
#' @param resid_err include residual error in the model? (no longer used, read from `model_filename`)
#' @param process_err include process error in the model? (no longer used, read from `model_filename`)
#' @export
#' @return jags.1, a \code{rjags} model object
#' 
#' \emph{Note: Tracer values are normalized before running the JAGS model.} This
#' allows the same priors to be used regardless of scale of the tracer data, 
#' without using the data to select the prior (i.e. by setting the prior mean equal
#' to the sample mean). Normalizing the tracer data does not affect the proportion
#' estimates (p_k), but does affect users seeking to plot the posterior predictive
#' distribution for their data. For each tracer, we calculate the pooled mean and
#' standard deviation of the mix and source data, then subtract the pooled mean 
#' and divide by the pooled standard deviation from the mix and source data. 
#' For details, see lines 226-269.
#'
run_model <- function(run, mix, source, discr, model_filename, alpha.prior = 1, resid_err=NULL, process_err=NULL){
  # get error structure from JAGS model text file line 8 
  err_raw <- read.table(model_filename, comment.char = '', sep=":", skip=7, nrows=1, colClasses="character")
  if(err_raw[1,2] == " Residual only") err <- "resid"
  if(err_raw[1,2] == " Process only (MixSIR, for N = 1)") err <- "process"
  if(err_raw[1,2] == " Residual * Process") err <- "mult"

  # Error checks on prior
  if(length(alpha.prior)==1){
    if(alpha.prior==1) alpha.prior = rep(1,source$n.sources)
  }
  if(!is.numeric(alpha.prior)){
    stop(paste("*** Error: Your prior is not a numeric vector of length(n.sources).
        Try again or choose the uninformative prior option. For example,
        c(1,1,1,1) is a valid (uninformative) prior for 4 sources. ***",sep=""))}
  if(length(alpha.prior) != source$n.sources){
    stop(paste("*** Error: Length of your prior does not match the
        number of sources (",source$n.sources,"). Try again. ***",sep=""))}
  if(length(which(alpha.prior==0))!=0){
    stop(paste("*** Error: You cannot set any alpha = 0.
      Instead, set = 0.01.***",sep=""))}

  if(is.numeric(alpha.prior)==F) alpha.prior = 1 # Error checking for user inputted string/ NA
  if(length(alpha.prior)==1) alpha = rep(alpha.prior,source$n.sources) # All sources have same value
  if(length(alpha.prior) > 1 & length(alpha.prior) != source$n.sources) alpha = rep(1,source$n.sources) # Error checking for user inputted string/ NA
  if(length(alpha.prior) > 1 & length(alpha.prior) == source$n.sources) alpha = alpha.prior # All sources have different value inputted by user

  # # Cannot set informative prior on fixed effects (no p.global)
  # if(!identical(unique(alpha),1) & mix$n.fe>0){
  # stop(paste("Cannot set an informative prior with a fixed effect,
  # since there is no global/overall population. You can set an
  # informative prior on p.global with a random effect.
  # To set a prior on each level of a fixed effect you will have to
  # modify 'write_JAGS_model.R'",sep=""))}

  # Set mcmc parameters
  if(is.list(run)){mcmc <- run} else { # if the user has entered custom mcmc parameters, use them
    if(run=="test") mcmc <- list(chainLength=1000, burn=500, thin=1, chains=3, calcDIC=TRUE)
    if(run=="very short") mcmc <- list(chainLength=10000, burn=5000, thin=5, chains=3, calcDIC=TRUE)
    if(run=="short") mcmc <- list(chainLength=50000, burn=25000, thin=25, chains=3, calcDIC=TRUE)
    if(run=="normal") mcmc <- list(chainLength=100000, burn=50000, thin=50, chains=3, calcDIC=TRUE)
    if(run=="long") mcmc <- list(chainLength=300000, burn=200000, thin=100, chains=3, calcDIC=TRUE)
    if(run=="very long") mcmc <- list(chainLength=1000000, burn=500000, thin=500, chains=3, calcDIC=TRUE)
    if(run=="extreme") mcmc <- list(chainLength=3000000, burn=1500000, thin=500, chains=3, calcDIC=TRUE)
  }

  n.sources <- source$n.sources
  N <- mix$N
  # make 'e', an Aitchision-orthonormal basis on the S^d simplex (equation 18, page 292, Egozcue 2003)
  # 'e' is used in the inverse-ILR transform (we pass 'e' to JAGS, where we do the ILR and inverse-ILR)
  e <- matrix(rep(0,n.sources*(n.sources-1)),nrow=n.sources,ncol=(n.sources-1))
  for(i in 1:(n.sources-1)){
    e[,i] <- exp(c(rep(sqrt(1/(i*(i+1))),i),-sqrt(i/(i+1)),rep(0,n.sources-i-1)))
    e[,i] <- e[,i]/sum(e[,i])
  }

  # other variables to give JAGS
  cross <- array(data=NA,dim=c(N,n.sources,n.sources-1))  # dummy variable for inverse ILR calculation
  tmp.p <- array(data=NA,dim=c(N,n.sources))              # dummy variable for inverse ILR calculation
  #jags.params <- c("p.global", "ilr.global")
  jags.params <- c("p.global","loglik")

  # Random/Fixed Effect data (original)
  # fere <- ifelse(mix$n.effects==2 & mix$n.re < 2,TRUE,FALSE)
  f.data <- character(0)
  if(mix$n.effects > 0 & !mix$fere){
    factor1_levels <- mix$FAC[[1]]$levels
    Factor.1 <- mix$FAC[[1]]$values
    cross.fac1 <- array(data=NA,dim=c(factor1_levels,n.sources,n.sources-1))  # dummy variable for inverse ILR calculation
    tmp.p.fac1 <- array(data=NA,dim=c(factor1_levels,n.sources))              # dummy variable for inverse ILR calculation
    if(mix$FAC[[1]]$re) jags.params <- c(jags.params, "p.fac1", "ilr.fac1", "fac1.sig") else jags.params <- c(jags.params, "p.fac1", "ilr.fac1")
    f.data <- c(f.data, "factor1_levels", "Factor.1", "cross.fac1", "tmp.p.fac1")
  }
  if(mix$n.effects > 1 & !mix$fere){
    factor2_levels <- mix$FAC[[2]]$levels
    Factor.2 <- mix$FAC[[2]]$values
    if(mix$fac_nested[1]) {factor2_lookup <- mix$FAC[[1]]$lookup; f.data <- c(f.data, "factor2_lookup");}
    if(mix$fac_nested[2]) {factor1_lookup <- mix$FAC[[2]]$lookup; f.data <- c(f.data, "factor1_lookup");}
    cross.fac2 <- array(data=NA,dim=c(factor2_levels,n.sources,n.sources-1))  # dummy variable for inverse ILR calculation
    tmp.p.fac2 <- array(data=NA,dim=c(factor2_levels,n.sources))              # dummy variable for inverse ILR calculation
    if(mix$FAC[[2]]$re) jags.params <- c(jags.params, "p.fac2", "ilr.fac2", "fac2.sig") else jags.params <- c(jags.params, "p.fac2", "ilr.fac2")
    f.data <- c(f.data, "factor2_levels", "Factor.2", "cross.fac2", "tmp.p.fac2")
  }

  # 2FE or 1FE + 1RE, don't get p.fac2
  # instead, get ilr.both[f1,f2,src], using fac2_lookup (list, each element is vector of fac 2 levels in f1)
  # but do get p.fac1 if fac1=FE and fac2=RE
  if(mix$fere){
    # set up factor 1 as fixed effect (if 1FE + 1RE, fac 1 is fixed effect)
    factor1_levels <- mix$FAC[[1]]$levels
    Factor.1 <- mix$FAC[[1]]$values
    if(mix$n.re==1){ # have p.fac1 (fixed) for 1 FE + 1 RE
      cross.fac1 <- array(data=NA,dim=c(factor1_levels,n.sources,n.sources-1))  # dummy variable for inverse ILR calculation
      tmp.p.fac1 <- array(data=NA,dim=c(factor1_levels,n.sources))              # dummy variable for inverse ILR calculation
      jags.params <- c(jags.params, "p.fac1")
      f.data <- c(f.data, "cross.fac1", "tmp.p.fac1")
    }

    # set up factor 2
    factor2_levels <- mix$FAC[[2]]$levels
    Factor.2 <- mix$FAC[[2]]$values
    # factor2_lookup <- list()
    # for(f1 in 1:factor1_levels){
    #   factor2_lookup[[f1]] <- unique(mix$FAC[[2]]$values[which(mix$FAC[[1]]$values==f1)])
    # }
    # f.data <- c(f.data,"factor2_lookup")

    # cross.both <- array(data=NA,dim=c(factor1_levels,factor2_levels,n.sources,n.sources-1))  # dummy variable for inverse ILR calculation
    # tmp.p.both <- array(data=NA,dim=c(factor1_levels,factor2_levels,n.sources))              # dummy variable for inverse ILR calculation
    # if(mix$FAC[[2]]$re) jags.params <- c(jags.params, "p.both", "fac2.sig") else jags.params <- c(jags.params, "p.both")
    # f.data <- c(f.data, "factor1_levels", "Factor.1", "factor2_levels", "Factor.2", "cross.both", "tmp.p.both")
    if(mix$FAC[[2]]$re) jags.params <- c(jags.params, "fac2.sig")
    jags.params <- c(jags.params,"ilr.global","ilr.fac1","ilr.fac2")
    f.data <- c(f.data, "factor1_levels", "Factor.1", "factor2_levels", "Factor.2")
  }

  # Source data
  if(source$data_type=="raw"){
    SOURCE_array <- source$SOURCE_array
    n.rep <- source$n.rep
    s.data <- c("SOURCE_array", "n.rep") # SOURCE_array contains the source data points, n.rep has the number of replicates by source and factor
  } else { # source$data_type="means"
    MU_array <- source$MU_array
    SIG2_array <- source$SIG2_array
    n_array <- source$n_array
    s.data <- c("MU_array", "SIG2_array", "n_array")  # MU has the source sample means, SIG2 the source variances, n_array the sample sizes
  }
  if(!is.na(source$by_factor)){       # include source factor level data, if we have it
    source_factor_levels <- source$S_factor_levels
    s.data <- c(s.data, "source_factor_levels")
  }
  if(source$conc_dep){
    conc <- source$conc
    s.data <- c(s.data, "conc")   # include Concentration Dependence data, if we have it
  }

  # Continuous Effect data
  c.data <- rep(NA,mix$n.ce)
  if(mix$n.ce > 0){                               # If we have any continuous effects
    for(ce in 1:mix$n.ce){                        # for each continuous effect
      name <- paste("Cont.",ce,sep="")
      assign(name,as.vector(mix$CE[[ce]]))
      c.data[ce] <- paste("Cont.",ce,sep="")  # add "Cont.ce" to c.data (e.g. c.data[1] <- Cont.1)
      jags.params <- c(jags.params,"ilr.global",paste("ilr.cont",ce,sep=""),"p.ind")   # add "ilr.cont(ce)" to jags.params (e.g. ilr.cont1)
    }
  }

  X_iso <- mix$data_iso
  n.iso <- mix$n.iso
  frac_mu <- discr$mu
  frac_sig2 <- discr$sig2
  # Always pass JAGS the following data:
  # all.data <- c("X_iso", "N", "n.sources", "n.iso", "alpha", "frac_mu", "frac_sig2", "e", "cross", "tmp.p")
  all.data <- c("X_iso", "N", "n.sources", "n.iso", "alpha", "frac_mu", "e", "cross", "tmp.p")
  jags.data <- c(all.data, f.data, s.data, c.data)
  # if(resid_err){
  #   jags.params <- c(jags.params,"var.resid")
  # }
  # if(process_err){
  #   jags.params <- c(jags.params,"mix.var")
  # }

  # Error structure objects
  I <- diag(n.iso)
  if(err=="resid" && mix$n.iso>1) jags.data <- c(jags.data,"I")
  if(err!="resid") jags.data <- c(jags.data,"frac_sig2")
  if(err=="mult") jags.params <- c(jags.params,"resid.prop")

  # Set initial values for p.global different for each chain
  jags.inits <- function(){list(p.global=as.vector(MCMCpack::rdirichlet(1,alpha)))}

  # Normalize tracer data. 2 reasons:
  #   1. Priors need to be on scale of data. This way we can keep same priors.
  #   2. Should facilitate fitting covariance
  # How:
  #   Pool all data for each tracer (source + mix)
  #   Calculate mean.pool and sd.pool
  #   Raw data:
  #     mix and source data: subtract mean.pool and divide by sd.pool
  #     frac mean and sd: divide by sd.pool
  #   Mean/SD/n data: 
  #     mix data: subtract mean.pool and divide by sd.pool
  #     source means: subtract mean.pool and divide by sd.pool
  #     source sd, frac mean, frac sd: divide by sd.pool
  for(j in 1:n.iso){
    if(source$data_type=="raw"){
      if(!is.na(source$by_factor)){ # source by factor, dim(SOURCE_array) = [src,iso,f1,r]
        mean.pool <- mean(c(X_iso[,j], as.vector(SOURCE_array[,j,,])), na.rm=T)
        sd.pool <- sd(c(X_iso[,j], as.vector(SOURCE_array[,j,,])), na.rm=T)
        SOURCE_array[,j,,] <- (SOURCE_array[,j,,] - mean.pool) / sd.pool
      } else { # source NOT by factor, dim(SOURCE_array) = [src,iso,r]
        mean.pool <- mean(c(X_iso[,j], as.vector(SOURCE_array[,j,])), na.rm=T)
        sd.pool <- sd(c(X_iso[,j], as.vector(SOURCE_array[,j,])), na.rm=T)
        SOURCE_array[,j,] <- (SOURCE_array[,j,] - mean.pool) / sd.pool
      }
    } else { # source data type = 'means'
      if(!is.na(source$by_factor)){ # source by factor,  MU_array[src,iso,f1] + SIG2_array[src,iso,f1]
          mean.pool <- (N*mean(X_iso[,j], na.rm=T) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j,]))) / sum(c(as.vector(n_array), N))
          if(N > 1) sd.pool <- sqrt((sum((as.vector(n_array)-1)*as.vector(SIG2_array[,j,])) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j,])^2) + (N-1)*stats::var(X_iso[,j], na.rm=T) + N*mean(X_iso[,j], na.rm=T)^2 - sum(c(as.vector(n_array), N))*mean.pool^2) / (sum(c(as.vector(n_array), N)) - 1))
          if(N == 1) sd.pool <- sqrt((sum((as.vector(n_array)-1)*as.vector(SIG2_array[,j,])) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j,])^2) + N*mean(X_iso[,j], na.rm=T)^2 - sum(c(as.vector(n_array), N))*mean.pool^2) / (sum(c(as.vector(n_array), N)) - 1))
          MU_array[,j,] <- (MU_array[,j,] - mean.pool) / sd.pool
          SIG2_array[,j,] <- SIG2_array[,j,] / sd.pool^2
      } else { # source NOT by factor, MU_array[src,iso] + SIG2_array[src,iso]
          mean.pool <- (N*mean(X_iso[,j], na.rm=T) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j]))) / sum(c(as.vector(n_array), N))
          if(N > 1) sd.pool <- sqrt((sum((as.vector(n_array)-1)*as.vector(SIG2_array[,j])) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j])^2) + (N-1)*stats::var(X_iso[,j], na.rm=T) + N*mean(X_iso[,j], na.rm=T)^2 - sum(c(as.vector(n_array), N))*mean.pool^2) / (sum(c(as.vector(n_array), N)) - 1))
          if(N == 1) sd.pool <- sqrt((sum((as.vector(n_array)-1)*as.vector(SIG2_array[,j])) + as.vector(as.vector(n_array)%*%as.vector(MU_array[,j])^2) + N*mean(X_iso[,j], na.rm=T)^2 - sum(c(as.vector(n_array), N))*mean.pool^2) / (sum(c(as.vector(n_array), N)) - 1))
          MU_array[,j] <- (MU_array[,j] - mean.pool) / sd.pool
          SIG2_array[,j] <- SIG2_array[,j] / sd.pool^2
      }
    }
    # for all source data scenarios, normalize mix and frac data the same way
    X_iso[,j] <- (X_iso[,j] - mean.pool) / sd.pool
    frac_mu[,j] <- frac_mu[,j] / sd.pool
    frac_sig2[,j] <- frac_sig2[,j] / sd.pool^2    
  }

  #############################################################################
  # Call JAGS
  #############################################################################
  jags.1 <- R2jags::jags(jags.data,
                                  inits=jags.inits,
                                  parameters.to.save = jags.params,
                                  model.file = model_filename,
                                  n.chains = mcmc$chains,
                                  n.burnin = mcmc$burn,
                                  n.thin = mcmc$thin,
                                  n.iter = mcmc$chainLength,
                                  DIC = mcmc$calcDIC)
  
  return(jags.1)
} # end run_model function

