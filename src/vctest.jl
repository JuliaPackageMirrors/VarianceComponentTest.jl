function vctest(y, X, V; bInit::Array{Float64, 1} = Float64[],
                devices::String = "CPU", nMMmax::Int = 0,
                nBlockAscent::Int = 1000, nNullSimPts::Int = 10000,
                nNullSimNewtonIter::Int = 15, tests::String = "eLRT",
                tolX::Float64 = 1e-6, vcInit::Array{Float64, 1} = Float64[],
                Vform::String = "whole", pvalueComputings::String = "chi2",
                WPreSim::Array{Float64, 2} = [Float64[] Float64[]],
                PrePartialSumW::Array{Float64, 2} = [Float64[] Float64[]],
                PreTotalSumW::Array{Float64, 2} = [Float64[] Float64[]],
                partialSumWConst::Array{Float64, 1} = Float64[],
                totalSumWConst::Array{Float64, 1} = Float64[],
                windowSize::Int = 50,
                partialSumW::Array{Float64, 1} = Float64[],
                totalSumW::Array{Float64, 1} = Float64[],
                lambda::Array{Float64, 2} = [Float64[] Float64[]],
                W::Array{Float64, 2} = [Float64[] Float64[]],
                nPreRank::Int = 20,
                tmpmat0::Array{Float64, 2} = [Float64[] Float64[]],
                tmpmat1::Array{Float64, 2} = [Float64[] Float64[]],
                tmpmat2::Array{Float64, 2} = [Float64[] Float64[]],
                tmpmat3::Array{Float64, 2} = [Float64[] Float64[]],
                tmpmat4::Array{Float64, 2} = [Float64[] Float64[]],
                tmpmat5::Array{Float64, 2} = [Float64[] Float64[]],
                denomvec::Array{Float64, 1} = Float64[],
                d1f::Array{Float64, 1} = Float64[],
                d2f::Array{Float64, 1} = Float64[],
                simnull::Array{Float64, 2} = [Float64[] Float64[]])
  # VCTEST Fit and test for the nontrivial variance component
  #
  # [SIMNULL] = VCTEST(y,X,V) fits and then tests for $H_0:sigma_1^2=0$ in
  # the variance components model $Y \sim N(X \beta, vc0*I + vc1*V)$.
  #
  #   INPUT:
  #       y - response vector
  #       X - design matrix for fixed effects
  #       V - the variance component being tested
  #
  #   Optional input name-value pairs:
  #       'nBlockAscent' - max block ascent iterations, default is 1000
  #       'nMMmax' - max MM iterations, default is 10 (eLRT) or 1000 (eRLRT)
  #       'nSimPts'- # simulation samples, default is 10000
  #       'test'- 'eLRT'|'eRLRT'|'eScore'|'none', the requested test, it also
  #           dictates the estimation method
  #       'tolX' - tolerance in change of parameters, default is 1e-5
  #       'Vform' - format of intpu V. 'whole': V, 'half': V*V', 'eigen':
  #           V.U*diag(V.E)*V.U'. Default is 'whole'. For computational
  #           efficiency,  a low rank 'half' should be used whenever possible
  #
  #   Output:
  #       b - estimated regression coeffiicents in the mean component
  #       vc0 - estiamted variance component for I
  #       vc1 - estiamted variance component for V
  #       stats - other statistics

  # include correlated files
  #include("typedef.jl");
  #include("vctestnullsim.jl");

  stats = Stats();

  # check dimensionalities
  n = length(y);
  if size(V, 1) != n
    error("vctest:wrongdimV\n", "dimension of V does not match that of X");
  end

  # set default maximum MM iteration
  if nMMmax == 0 && tests == "eLRT"
    nMMmax = 10;
  elseif nMMmax == 0 && tests == "eRLRT"
    nMMmax = 1000;
  end

  # SVD of X
  if isempty(X)
    rankX = 0;
    X = reshape(X, n, 0);
    X = convert(Array{Float64, 2}, X);
    # LRT is same as RLRT if X is null
    if tests == "eLRT"
      tests = "eRLRT";
    end
  else
    if tests == "eRLRT"
      (UX, svalX) = svd(X, thin = false);
    else
      (UX, svalX) = svd(X);
    end
    rankX = countnz(svalX .> n * eps(svalX[1]));
  end

  # eigendecomposition of V
  if Vform == "whole"
    (evalV, UV) = eig(V);
    rankV = countnz(evalV .> n * eps(sqrt(maximum(evalV))));
    sortIdx = sortperm(evalV, rev = true);
    evalV = evalV[sortIdx[1:rankV]];
    UV = UV[:, sortIdx[1:rankV]];
    if tests == "eLRT" || tests == "eRLRT"
      wholeV = V;
    end
  elseif Vform == "half"
    (UV, evalV) = svd(V);
    rankV = countnz(evalV .> n * eps(maximum(evalV)));
    evalV = evalV[1:rankV] .^ 2;
    UV = UV[:, 1:rankV];
    #if tests == "eLRT" || tests == "eRLRT"
    #  wholeV = *(V, V');
    #end
  elseif Vform == "eigen"
    UV = V.U;
    evalV = V.eval;
    rankV = countnz(V.eval .> n * eps(sqrt(maximum(V.eval))));
    sortIdx = sortperm(V.eval, rev = true);
    V.eval = V.eval[sortIdx[1:rankV]];
    V.U = V.U[:, sortIdx[1:rankV]];
    if tests == "eLRT" || tests == "eRLRT"
      wholeV = *(V.U .* reshape(V.eval, length(V.eval), 1), V.U');
    end
  end

  # obtain eigenvalues of (I-PX)V(I-PX)
  if !isempty(X) || tests == "eScore"
    sqrtV = UV .* sqrt(evalV)';
  end
  #sqrtV = UV;
  #scale!(sqrtV, sqrt(evalV));
  if isempty(X)
    evalAdjV = evalV;
  else
    (UAdjV, evalAdjV) = svd(sqrtV - *(UX[:, 1:rankX], *(UX[:,1:rankX]', sqrtV)),
                            thin = false);
    evalAdjV = evalAdjV[evalAdjV .> n * eps(maximum(evalAdjV))] .^ 2;
  end
  rankAdjV = length(evalAdjV);

  # fit the variance component model
  if tests == "eLRT"

    # estimates under null model
    bNull = X \ y;
    rNull = y - X * bNull;
    vc0Null = norm(rNull) ^ 2 / n;
    Xrot = UV' * X;
    yrot = UV' * y;
    loglConst = - 0.5 * n * log(2.0 * pi);

    # set starting point
    if isempty(bInit)
      b = bNull;
      r = rNull;
    else
      b = bInit;
      r = y - X * b;
    end
    if isempty(vcInit)
      vc0 = norm(r) ^ 2 / n;
      vc1 = 1;
      wt = 1.0 ./ sqrt(vc1 * evalV + vc0);
      Xnew = scale(wt, Xrot);
      ynew = wt .* yrot;
      res = ynew - Xnew * b;
    else
      vc0 = vcInit[1];
      # avoid sticky boundary
      if vc0 == 0
        vc0 = 1e-4;
      end
      vc1 = vcInit[2];
      if vc1 == 0
        vc1 = 1e-4;
      end
      wt = 1.0 ./ sqrt(vc1 * evalV + vc0);
      Xnew = scale(wt, Xrot);
      ynew = wt .* yrot;
      b = Xnew \ ynew;
      res = ynew - Xnew * b;
    end

    # update residuals according supplied var. components
    r = y - X * b;
    #rnew = UV'*r;
    deltaRes = norm(r) ^ 2 - norm(res ./ wt) ^ 2;

    nIters = 0;
    for iBlockAscent = 1:nBlockAscent

      nIters = iBlockAscent;

      # update variance components
      for iMM = 1:nMMmax
        res = res .* wt;
        wt = wt .* wt;
        #tmpvec = vc0 + vc1*evalV;
        #denvec = 1./tmpvec; # same as wt
        #numvec = (rnew .* denvec).^2;
        vc0 = sqrt( (vc0 ^ 2 * sumabs2(res) + deltaRes) /
                     (sumabs(wt) + (n - rankV) / vc0) );
        vc1 = vc1 * sqrt( dot(res, res .* evalV) / sum(evalV .* wt) );
      end

      # update fixed effects and residuals
      bOld = b;
      wt = 1.0 ./ sqrt(vc1 * evalV + vc0);
      Xnew = scale(wt, Xrot);
      ynew = wt .* yrot;
      b = Xnew \ ynew;
      res = ynew - Xnew * b;
      r = y - X * b;
      #rnew = UV'*r;
      deltaRes = norm(r) ^ 2 - norm(res ./ wt) ^ 2;

      # stopping criterion
      if norm(b - bOld) <= tolX * (norm(bOld) + 1)
        break
      end

    end

    # log-likelihood at alternative
    logLikeAlt = loglConst + sum(log, wt) - 0.5 * (n - rankV) * log(vc0) -
      0.5 * deltaRes / vc0 - 0.5 * sumabs2(res);
    # log-likelihood at null
    logLikeNull = loglConst - 0.5 * n * log(vc0Null) -
      0.5 * sum(rNull .^ 2) / vc0Null;
    if logLikeNull >= logLikeAlt
      vc0 = vc0Null;
      vc1 = 0;
      logLikeAlt = logLikeNull;
      b = bNull;
      r = rNull;
    end

    # LRT test statistic
    statLRT = 2 * (logLikeAlt - logLikeNull);

    # obtain p-value for testing vc1=0
    stats.vc1_pvalue = vctestnullsim(statLRT, evalV, evalAdjV, n, rankX,
                                     WPreSim, device = devices,
                                     nSimPts = nNullSimPts,
                                     nNewtonIter = nNullSimNewtonIter,
                                     test = "eLRT",
                                     pvalueComputing = pvalueComputings,
                                     PrePartialSumW = PrePartialSumW,
                                     PreTotalSumW = PreTotalSumW,
                                     partialSumWConst = partialSumWConst,
                                     totalSumWConst = totalSumWConst,
                                     windowSize = windowSize,
                                     partialSumW = partialSumW,
                                     totalSumW = totalSumW,
                                     lambda = lambda, W = W,
                                     nPreRank = nPreRank,
                                     tmpmat0 = tmpmat0, tmpmat1 = tmpmat1,
                                     tmpmat2 = tmpmat2, tmpmat3 = tmpmat3,
                                     tmpmat4 = tmpmat4, tmpmat5 = tmpmat5,
                                     denomvec = denomvec,
                                     d1f = d1f, d2f = d2f, simnull = simnull);
    stats.vc1_pvalue_se = sqrt(stats.vc1_pvalue * (1 - stats.vc1_pvalue) /
                                 nNullSimPts);
    stats.vc1_teststat = statLRT;

    # collect some statistics
    stats.iterations = nIters;
    stats.method = "MLE";
    stats.residual = r;
    stats.test = "eLRT";

    # return values
    return b, vc0, vc1, stats;

  elseif tests == "eRLRT"

    if isempty(X)
      ytilde = y;
      rankBVB = rankV;
      evalBVB = evalV;
      UBVB = UV;
    else
      # obtain a basis of N(X')
      B = UX[:, rankX+1:end];
      ytilde = B' * y;

      # eigen-decomposition of B'VB and transform data
      (UBVB, evalBVB) = svd(B' * sqrtV);
      rankBVB = countnz(evalBVB .> n * eps(maximum(evalBVB)));
      evalBVB = evalBVB[1:rankBVB] .^ 2;
      UBVB = UBVB[:, 1:rankBVB];
    end
    resnew = UBVB' * ytilde;
    normYtilde2 = norm(ytilde) ^ 2;
    deltaRes = normYtilde2 - norm(resnew) ^ 2;

    # set initial point
    # TODO: is there better initial point?
    vc0Null = normYtilde2 / length(ytilde);
    if isempty(vcInit)
      vc0 = vc0Null;
      vc1 = 1.0;
    else
      vc0 = vcInit[1];
      vc1 = vcInit[2];
    end

    # MM loop for estimating variance components
    nIters = 0;
    #tmpvec = Array(Float64, rankBVB);
    #denvec = Array(Float64, rankBVB);
    #numvec = Array(Float64, rankBVB);
    tmpvec = Float64[];
    for iMM = 1:nMMmax
      nIters = iMM;
      #tmpvec = vc0 + vc1 * evalBVB;
      #tmpvec = evalBVB;
      #numvecSum = 0.0;
      #denvecSum = 0.0;
      #numvecProdSum = 0.0;
      #denvecProdSum = 0.0;
      tmpvec = BLAS.scal(rankBVB, vc1, evalBVB, 1);
      #for i = 1 : rankBVB
      #  tmpvec[i] += vc0;
      #  denvec[i] = 1 / tmpvec[i];
      #  numvec[i] = (resnew[i] * denvec[i]) ^ 2;
      #  numvecSum += numvec[i];
      #  denvecSum += denvec[i];
      #  numvecProdSum += evalBVB[i] * numvec[i];
      #  denvecProdSum += evalBVB[i] * denvec[i];
      #end
      tmpvec += vc0;
      denvec = 1 ./ tmpvec;
      numvec = (resnew .* denvec) .^ 2;
      vcOld = [vc0 vc1];
      vc0 = sqrt( (vc0 ^ 2 * sum(numvec) + deltaRes) /
                   (sum(denvec) + (n - rankX - rankBVB) / vc0) );
      #vc0 = sqrt( (vc0 ^ 2 * numvecSum + deltaRes) /
      #             (denvecSum + (n - rankX - rankBVB) / vc0) );
      vc1 = vc1 * sqrt( sum(evalBVB .* numvec) / sum(evalBVB .* denvec) );
      #vc1 = vc1 * sqrt( numvecProdSum / denvecProdSum );
      # stopping criterion
      if norm([vc0 vc1] - vcOld) <= tolX * (norm(vcOld) + 1)
        break;
      end
    end

    # restrictive log-likelihood at alternative

    loglConst = - 0.5 * (n - rankX) * log(2 * pi);
    logLikeAlt =  loglConst - 0.5 * sum(log(tmpvec)) -
      0.5 * (n - rankX - rankBVB) * log(vc0) - 0.5 * normYtilde2 / vc0 +
      0.5 * sum(resnew .^ 2 .* (1 / vc0 - 1 ./ (tmpvec)));
    # restrictive log-likelihood at null
    logLikeNull = - 0.5 * (n - rankX) * (log(2 * pi) + log(vc0Null)) -
      0.5 / vc0Null * normYtilde2;
    if logLikeNull >= logLikeAlt
      vc0 = vc0Null;
      vc1 = 0;
      logLikeAlt = logLikeNull;
    end

    # RLRT test statitic
    statRLRT = 2 * (logLikeAlt - logLikeNull);

    # obtain p-value for testing vc1=0
    stats.vc1_pvalue = vctestnullsim(statRLRT, evalV, evalAdjV, n, rankX,
                                     WPreSim, device = devices,
                                     nSimPts = nNullSimPts,
                                     nNewtonIter = nNullSimNewtonIter,
                                     test = "eRLRT",
                                     pvalueComputing = pvalueComputings,
                                     PrePartialSumW = PrePartialSumW,
                                     PreTotalSumW = PreTotalSumW,
                                     partialSumWConst = partialSumWConst,
                                     totalSumWConst = totalSumWConst,
                                     windowSize = windowSize,
                                     partialSumW = partialSumW,
                                     totalSumW = totalSumW,
                                     lambda = lambda, W = W,
                                     nPreRank = nPreRank,
                                     tmpmat0 = tmpmat0, tmpmat1 = tmpmat1,
                                     tmpmat2 = tmpmat2, tmpmat3 = tmpmat3,
                                     tmpmat4 = tmpmat4, tmpmat5 = tmpmat5,
                                     denomvec = denomvec,
                                     d1f = d1f, d2f = d2f, simnull = simnull);
    stats.vc1_pvalue_se = sqrt(stats.vc1_pvalue * (1 - stats.vc1_pvalue) /
                                 nNullSimPts);

    # estimate fixed effects
    if isempty(X)
      b = zeros(0);
    else
      Xrot = UV' * X;
      yrot = UV' * y;
      wt = 1.0 ./ sqrt(vc1 * evalV + vc0);
      Xnew = scale(wt, Xrot);
      ynew = wt .* yrot;
      b = Xnew \ ynew;
    end

    # collect some statistics
    stats.iterations = nIters;
    stats.method = "REML";
    #stats.residual = y - X * b;
    stats.residual = y;
    BLAS.gemv!('N', -1.0, X, b, 1.0, stats.residual);
    stats.test = "eRLRT";
    stats.vc1_teststat = statRLRT;

    # return values
    return b, vc0, vc1, stats;

  elseif tests == "eScore"

    # fit the null model
    b = X \ y;
    r = y - X * b;
    vc0 = norm(r) ^ 2 / n;
    vc1 = 0;

    # score test statistic
    statScore = norm(r' * sqrtV) ^ 2 / norm(r) ^ 2;

    # obtain p-value for testing vc1=0
    stats.vc1_pvalue = vctestnullsim(statScore, evalV, evalAdjV, n, rankX,
                                     WPreSim, test = "eScore",
                                     nSimPts = nNullSimPts,
                                     pvalueComputing = pvalueComputings,
                                     nNewtonIter = nNullSimNewtonIter,
                                     device = devices,
                                     PrePartialSumW = PrePartialSumW,
                                     PreTotalSumW = PreTotalSumW,
                                     partialSumWConst = partialSumWConst,
                                     totalSumWConst = totalSumWConst,
                                     windowSize = windowSize,
                                     partialSumW = partialSumW,
                                     totalSumW = totalSumW,
                                     lambda = lambda, W = W,
                                     nPreRank = nPreRank,
                                     tmpmat0 = tmpmat0, tmpmat1 = tmpmat1,
                                     tmpmat2 = tmpmat2, tmpmat3 = tmpmat3,
                                     tmpmat4 = tmpmat4, tmpmat5 = tmpmat5,
                                     denomvec = denomvec,
                                     d1f = d1f, d2f = d2f, simnull = simnull);
    stats.vc1_pvalue_se = sqrt(stats.vc1_pvalue * (1 - stats.vc1_pvalue) /
                                 nNullSimPts);

    # collect some statistics
    stats.iterations = 0;
    stats.method = "null";
    stats.residual = r;
    stats.test = "eScore";
    stats.vc1_teststat = statScore;

    # return values
    return b, vc0, vc1, stats;

  end

end
