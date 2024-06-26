library(limma)
library(parallel)

RAISINfit <- function(expr,sample,testtype,design,intercept=TRUE,filtergene=F,filtergenequantile=0.5,ncores=detectCores(),seed=12345) {
  # presettings
  set.seed(seed)
  if (sum(duplicated(rownames(expr))) > 1) {
    print('Remove duplicated row names')
    id <- which(!duplicated(rownames(expr)))
    expr <- expr[id,]
  }
  if (testtype!='custom') {
    samplename <- as.character(design[,'sample'])
    X <- design[,'feature']  
    if (testtype=='unpaired') {
      Z <- model.matrix(~.-1,data.frame(sample=design[,'sample']))
      colnames(Z) <- sub('^sample','',colnames(Z))
      group <- as.character(design[match(colnames(Z),design[,'sample']),'feature'])
    } else if (testtype=='continuous') {
      Z <- model.matrix(~.-1,data.frame(sample=design[,'sample']))
      colnames(Z) <- sub('^sample','',colnames(Z))
      group <- rep('group',ncol(Z))
    } else if (testtype=='paired') {
      if (sum(table(design[,'individual'])==2) < 2) {
        print('Less than two pairs detected. Switch to unpaired test.')
        Z <- model.matrix(~.-1,data.frame(sample=design[,'sample']))
        colnames(Z) <- sub('^sample','',colnames(Z))
        group <- as.character(design[match(colnames(Z),design[,'sample']),'feature'])
      } else {
        Z <- model.matrix(~.-1,data.frame(sample=design[,'individual']))
        colnames(Z) <- sub('^sample','',colnames(Z))
        tab <- table(X)
        Z2 <- diag(nrow(design))
        Z2 <- Z2[,X==names(which.max(tab)),drop=F]
        group <- rep(c('individual','difference'),c(ncol(Z),ncol(Z2)))
        Z <- cbind(Z,Z2)
      }
    }
    names(group) <- colnames(Z)
    if(intercept) {
      X <- model.matrix(~.,data.frame(X))
    } else {
      X <- model.matrix(~.-1,data.frame(X))
    }
  } else {
    X <- design[['X']]
    Z <- design[['Z']]
    group <- as.character(design[['group']])
    samplename <- row.names(X)
  }
  
  # estimate average across within sample
  means <- sapply(samplename,function(us) {
    rowMeans(expr[,sample==us,drop=F])
  })
  
  # filtering genes
  if (filtergene) {
    m <- quantile(means,filtergenequantile)
    gid <- rowSums(means > m) > 0
    expr <- expr[gid,]
    means <- means[gid,]
  }
  G <- nrow(expr)
  
  # read in gaussian quadrature weights and nodes
  gaussquad <- readRDS('/home-4/zji4@jhu.edu/scratch/raisin/software/raisin/gaussquad/gaussquad.rds')
  useid <- which(gaussquad[[2]] > 0)
  node <- gaussquad[[1]][useid]
  lognode <- log(node)
  logweight <- log(gaussquad[[2]][useid])
  
  #  if (filtergene) {
  #m <- quantile(expr,filtergenequantile)
  #gid <- sapply(samplename,function(sp) {
  #  names(which(rowMeans(expr[,sample==sp,drop=F] > m) > 0.1))
  #})
  #gid <- unique(unlist(gid))
  #expr <- expr[gid,]
  #  }
  # estimate cell-level variance
  w <- sapply(samplename,function(us) {
    sampid <- which(sample==us)
    if (length(sampid) > 1) {
      d <- length(sampid)-1
      s2 <- (rowMeans(expr[,sampid]*expr[,sampid]) - means[,us]^2) * ((d + 1)/d)
      stat <- var(log(s2[s2 > 0]))-trigamma(d/2)
      if (stat > 0) {
        theta <- trigammaInverse(stat)
        phi <- exp(mean(log(s2[s2 > 0]))-digamma(d/2)+digamma(theta))*d/2
        if (theta+d/2 > 1) {
          (d*s2/2+phi)/(theta+d/2-1)
        } else {
          sapply(s2,function(ss2) {
            alpha <- theta+d/2
            beta <- d*ss2/2+phi
            beta^alpha/gamma(alpha) * sum(exp(node-alpha*lognode-beta/node+logweight))
          })
        }
      } else {
        rep(exp(mean(log(s2[s2 > 0]))),G)
      }
    } else {
      rep(NA,G)
    }
  })
  rm('expr')
  zid <- names(which(colMeans(is.na(w)) == 1))
  nzid <- setdiff(colnames(w),zid)
  Xdist <- as.matrix(dist(X))
  row.names(Xdist) <- colnames(Xdist) <- samplename
  if (length(zid) > 0 & length(nzid) > 0) {
    for (sid in zid) {
      if (length(nzid)==1) {
        w[,sid] <- w[,nzid]
      } else {
        tarid <- names(which(Xdist[sid,nzid]==min(Xdist[sid,nzid])))
        w[,sid] <- rowMeans(w[,tarid,drop=F])
      }
    }
  }
  wl <- sapply(samplename,function(us) {
    sum(sample==us)
  })
  w <- t(t(w) / wl)
  
  failgroup <- NULL
  # estimate sample-level variance
  #currentgroup=ug;controlgroup=setdiff(tmpcontrolgroup,ug);donegroup=tmpdonegroup
  sigma2func <- function(currentgroup,controlgroup,donegroup) {
    Xl <- cbind(X,Z[,group %in% controlgroup,drop=F])
    Zl <- Z[,group==currentgroup,drop=F]
    # get all rows that involves either current or control random effects
    lid <- which(rowSums(Z[,group %in% c(currentgroup,controlgroup),drop=F]) > 0)
    Xl <- Xl[lid,,drop=F]
    Zl <- Zl[lid,,drop=F]
    # make X full rank
    Xl <- Xl[, qr(Xl)$pivot[seq_len(qr(Xl)$rank)],drop=F]
    n <- length(lid)
    p <- n-ncol(Xl)
    
    if (p==0) {
      failgroup <<- c(failgroup,currentgroup)
      warning('Unable to estimate variance for group ',currentgroup,', setting its variance estimate to 0.')
      rep(0,G)
    } else {
      K <- matrix(rnorm(n*p),nrow=n,ncol=p)
      for (i in 1:p) {
        b <- Xl
        if (i > 1) {
          for (j in 1:(i-1)) {
            b <- cbind(b,K[,j])
          }
        }
        K[,i] <- K[,i] - b %*% chol2inv(chol(t(b) %*% b)) %*% t(b) %*% K[,i]
      }
      K <- sweep(K,2,sqrt(colSums(K^2)),'/')
      K <- t(K)
      
      pl <- t(K %*% t(means[,lid]))
      qlm <- K %*% Zl %*% t(Zl) %*% t(K)
      ql <- diag(qlm)
      
      rl <- w[,lid] %*% t(K^2)
      
      for (sg in donegroup) {
        KZmat <- K %*% Z[lid,group==sg,drop=F] %*% t(Z[lid,group==sg,drop=F]) %*% t(K)
        tmp <- sapply(1:nrow(w),function(rid) diag(sigma2[,sg][i] * KZmat))
        if (is.vector(tmp)) tmp <- matrix(tmp,nrow=1)
        rl <- rl + t(tmp)
      }
      
      M <- mean(pmax(0,t(pl^2-rl)/ql))
      V <- mean(pmax(0,t(pl^4-3*rl^2-6*M*ql*rl)/3/(ql^2)))
      alpha <- M^2/(V-M^2)
      gamma <- M/(V-M^2)
      print(paste0("alpha=",alpha,' beta=',gamma))
      
      if ((is.nan(alpha) | is.nan(gamma)) || (alpha<=0 | gamma <=0)) {
        print('Invalid hyperparameters. Proceed without variance pooling.')
        est <- unlist(mclapply(1:G,function(id) {
          rootres <- NULL
          tryCatch({rootres <- uniroot(function(s2) {sum((s2*ql^2+ql*rl[id,]-pl[id,]^2*ql)/(s2*ql+rl[id,])^2)},c(0,1000))$root},warning=function(w) {},error=function(e) {})
          if (is.null(rootres)) {
            0
          } else {
            rootres
          }
        },mc.cores=ncores))
      } else {
        tK <- t(K)
        scomb <- mclapply(1:G,function(id) {
          suppressWarnings(rm('res'))
          tmpx <- tcrossprod(pl[id,])
          tmpw <- w[id,lid]
          t2 <- crossprod(tK, (tmpw * tK))
          tryCatch(res <- sapply(node,function(gn) {
            cm <- chol(gn * qlm + t2)
            -log(prod(diag(cm)^2))-sum(tmpx * chol2inv(cm))
          }),error=function(e) {},warning=function(w) {})  
          # to handle rare case of numerical issue
          while(!exists('res')) {
            tmpw[which.min(tmpw)] <- tmpw[which.min(tmpw)]*2
            t2 <- crossprod(tK, (tmpw * tK))
            tryCatch(res <- sapply(node,function(gn) {
              cm <- chol(gn * qlm + t2)
              -log(prod(diag(cm)^2))-sum(tmpx * chol2inv(cm))
            }),error=function(e) {},warning=function(w) {})  
          }
          res
        },mc.cores = ncores)
        scomb <- do.call(cbind,scomb)/2
        
        tmp <- logweight + node + scomb + (alpha-1) * lognode - gamma*node
        est <- colSums(exp(tmp + lognode))/colSums(exp(tmp))
        est[is.na(est)] <- 1
        id <- which(est==Inf)
        if (length(id) > 0) {
          for (sid in id) {
            v1 <- (tmp + lognode)[,id]
            v2 <- tmp[,id]
            mv <- max(c(v1,v2))
            est[id] <- sum(exp(v1-mv))/sum(exp(v2-mv))
          }
        }
        est  
      }
    }
  }
  
  sigma2 <- matrix(0,nrow=G,ncol=length(unique(group)))
  colnames(sigma2) <- unique(group)
  tmpcontrolgroup <- colnames(sigma2)
  tmpdonegroup <- NULL
  npara <- sapply(colnames(sigma2),function(ug) {
    sum(rowSums(Z[,group==ug,drop=F] > 0) > 0)
  })
  for (ug in names(sort(npara))) {
    print(paste0("Estimating sigma2 for group: ",ug))
    sigma2[,ug] <- sigma2func(ug,setdiff(tmpcontrolgroup,ug),tmpdonegroup)
    tmpcontrolgroup <- setdiff(tmpcontrolgroup,ug)
    tmpdonegroup <- c(tmpdonegroup,ug)
  }
  list(mean=means,sigma2=sigma2,omega2=w,X=X,Z=Z,group=group,failgroup=failgroup)
}

RAISINtest <- function(fit,coef=2,contrast=NULL) {
  X <- fit$X
  means <- fit$mean
  G <- nrow(means)
  group <- fit$group
  Z <- fit$Z
  if (is.null(contrast)) {
    contrast <- rep(0,ncol(X))
    contrast[coef] <- 1
  }
  k <- t(contrast) %*% solve(t(X) %*% X) %*% t(X)
  b <- (means %*% t(k))[,1]
  if (identical(unique(fit$group),fit$failgroup)) {
    warning('Unable to estimate variance for all random effects. Setting FDR to 1.')
    res <- data.frame(Foldchange=b,FDR=1,stringsAsFactors=F)
    res[order(-abs(res[,1])),]
  } else {
    a <- colSums((k %*% Z)[1,]^2 * t(fit$sigma2[,group])) + colSums(k[1,]^2 * t(fit$omega2))
    stat <- b/sqrt(a)
    
    simustat <- unlist(lapply(1:10,function(simuid) {
      perX <- X[sample(1:nrow(X)),]
      k <- t(contrast) %*% solve(t(perX) %*% perX) %*% t(perX)
      a <- colSums((k %*% Z)[1,]^2 * t(fit$sigma2[,group])) + colSums(k[1,]^2 * t(fit$omega2))
      (means %*% t(k))[,1]/sqrt(a)
    }))
    
    pnorm <- sum(dnorm(simustat,log=T))
    pt <- sapply(seq(1,100,0.1),function(dt) {
      sum(dt(simustat,df=dt,log=T))  
    })
    
    if (max(pt) > pnorm) {
      df <- seq(1,100,0.1)[which.max(pt)]
      pval <- pt(abs(stat),df,lower.tail = F) * 2
    } else {
      pval <- pnorm(abs(stat),lower.tail = F) * 2
    }
    
    fdr <- p.adjust(pval,method='fdr')
    res <- data.frame(Foldchange=b,stat=stat,pvalue=pval,FDR=fdr,stringsAsFactors=F)
    res <- res[order(res[,4],-abs(res[,2])),]
    res
  }
}
