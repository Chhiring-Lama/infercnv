
define_signif_tumor_subclusters <- function(infercnv_obj,
                                            p_val=0.1,
                                            k_nn=20,
                                            leiden_resolution=0.05,
                                            leiden_method=c("PCA", "simple"),
                                            leiden_function = "CPM",
                                            hclust_method="ward.D2",
                                            cluster_by_groups=TRUE,
                                            partition_method="leiden",
                                            per_chr_hmm_subclusters=TRUE,
                                            z_score_filter=0.8,
                                            restrict_to_DE_genes=FALSE) 
{
    # leiden_method=c("simple", "per_chr", "intersect_chr", "per_select_chr", "PCA", "seurat2")
    flog.info(sprintf("define_signif_tumor_subclusters(p_val=%g", p_val))
    
    # tumor_groups <- infercnv_obj@observation_grouped_cell_indices

    res = list()

    if (restrict_to_DE_genes) {
        normal_expr_data = infercnv_obj@expr.data[, unlist(infercnv_obj@reference_grouped_cell_indices) ]
    }
    
    tumor_groups = list()

    if (cluster_by_groups) {
        tumor_groups <- c(infercnv_obj@observation_grouped_cell_indices, infercnv_obj@reference_grouped_cell_indices)
    }
    else {
        # if(length(infercnv_obj@reference_grouped_cell_indices) > 0) {
        tumor_groups <- c(list(all_observations=unlist(infercnv_obj@observation_grouped_cell_indices, use.names=FALSE)), infercnv_obj@reference_grouped_cell_indices)
        # }
        # else {
        #     tumor_groups <- list(all_observations=unlist(infercnv_obj@observation_grouped_cell_indices, use.names=FALSE))
        # }
    }

    outliers = NULL
    # if (partition_method == "leiden" && grepl("filter", leiden_method, fixed=TRUE)) {
    if (z_score_filter > 0) {
        ref_matrix = infercnv_obj@expr.data[, unlist(infercnv_obj@reference_grouped_cell_indices), drop=FALSE]
        z_score = (ref_matrix - mean(ref_matrix))/sd(ref_matrix)
        outliers =  which(apply(abs(z_score), 1, mean) >= 0.8)

        if (!is.null(outliers)) {
            chrs = infercnv_obj@gene_order$chr[-outliers]
        }
        # leiden_method = "seurat" leiden_method[1:(length(leiden_method) - 7)]
        rm(ref_matrix)
        rm(z_score)
    }
    else {
        chrs = infercnv_obj@gene_order$chr
    }

    for (tumor_group in names(tumor_groups)) {

        flog.info(sprintf("define_signif_tumor_subclusters(), tumor: %s", tumor_group))
        
        tumor_group_idx <- tumor_groups[[ tumor_group ]]
        names(tumor_group_idx) <- colnames(infercnv_obj@expr.data[,tumor_group_idx])
        tumor_expr_data <- infercnv_obj@expr.data[,tumor_group_idx, drop=FALSE]

        if (restrict_to_DE_genes) {
            p_vals <- .find_DE_stat_significance(normal_expr_data, tumor_expr_data)
            
            DE_gene_idx = which(p_vals < p_val)
            tumor_expr_data = tumor_expr_data[DE_gene_idx, , drop=FALSE]
            
        }
        
        if (partition_method == "leiden") {

            if (!is.null(outliers)) {
                tumor_expr_data = tumor_expr_data[-outliers, , drop=FALSE]
            }

            #tumor_subcluster_info <- .single_tumor_leiden_subclustering(tumor_group=tumor_group, tumor_group_idx=tumor_group_idx, tumor_expr_data=tumor_expr_data, chrs=infercnv_obj@gene_order$chr, k_nn=k_nn, leiden_resolution=leiden_resolution, leiden_method=leiden_method, select_chr=select_chr, hclust_method=hclust_method)
            tumor_subcluster_info <- .single_tumor_leiden_subclustering(tumor_group=tumor_group,
                                                                        tumor_group_idx=tumor_group_idx,
                                                                        tumor_expr_data=tumor_expr_data,
                                                                        chrs=chrs,
                                                                        k_nn=k_nn,
                                                                        leiden_resolution=leiden_resolution,
                                                                        leiden_method=leiden_method,
                                                                        leiden_function=leiden_function,
                                                                        hclust_method=hclust_method
                                                                        )
        }
        else {
            tumor_subcluster_info <- .single_tumor_subclustering(tumor_name=tumor_group,
                                                                 tumor_group_idx=tumor_group_idx,
                                                                 tumor_expr_data=tumor_expr_data,
                                                                 p_val=p_val,
                                                                 hclust_method=hclust_method,
                                                                 partition_method=partition_method
                                                                 )
        }

        res$hc[[tumor_group]] <- tumor_subcluster_info$hc
        res$subclusters[[tumor_group]] <- tumor_subcluster_info$subclusters

    }

    infercnv_obj@tumor_subclusters <- res

    if (per_chr_hmm_subclusters && partition_method == "leiden") {
        if (!is.null(outliers)) {
            tumor_expr_data = infercnv_obj@expr.data[-outliers, , drop=FALSE]
        }
        subclusters_per_chr <- .whole_dataset_leiden_subclustering_per_chr(expr_data = tumor_expr_data,
                                                                           chrs = chrs,
                                                                           k_nn = k_nn,
                                                                           leiden_resolution = (leiden_resolution/10),
                                                                           leiden_function = leiden_function
                                                                           )
    }
    else {
        subclusters_per_chr = NULL
    }

    if (! is.null(infercnv_obj@.hspike)) {
        flog.info("-mirroring for hspike")
        infercnv_obj@.hspike = define_signif_tumor_subclusters(infercnv_obj@.hspike,
                                                               p_val=p_val,
                                                               k_nn=k_nn,
                                                               leiden_resolution=leiden_resolution,
                                                               leiden_method="simple",
                                                               hclust_method=hclust_method,
                                                               cluster_by_groups=cluster_by_groups,
                                                               partition_method=partition_method,
                                                               per_chr_hmm_subclusters=FALSE,
                                                               restrict_to_DE_genes=restrict_to_DE_genes)[[1]]
    }
        
    #browser()
    # return(infercnv_obj)
    return(list(infercnv_obj, subclusters_per_chr))
}



.single_tumor_subclustering <- function(tumor_name, tumor_group_idx, tumor_expr_data, p_val, hclust_method,
                                        partition_method=c('qnorm', 'pheight', 'qgamma', 'shc', 'none')
                                        ) {
    
    partition_method = match.arg(partition_method)
    
    tumor_subcluster_info = list()
    
    if (ncol(tumor_expr_data) > 2) {

        hc <- hclust(parallelDist(t(tumor_expr_data), threads=infercnv.env$GLOBAL_NUM_THREADS), method=hclust_method)
        
        tumor_subcluster_info$hc = hc
        
        heights = hc$height

        grps <- NULL
        
        if (partition_method == 'pheight') {

            cut_height = p_val * max(heights)
            flog.info(sprintf("cut height based on p_val(%g) = %g and partition_method: %s", p_val, cut_height, partition_method))
            grps <- cutree(hc, h=cut_height) # will just be one cluster if height > max_height

            
        } else if (partition_method == 'qnorm') {

            mu = mean(heights)
            sigma = sd(heights)
            
            cut_height = qnorm(p=1-p_val, mean=mu, sd=sigma)
            flog.info(sprintf("cut height based on p_val(%g) = %g and partition_method: %s", p_val, cut_height, partition_method))
            grps <- cutree(hc, h=cut_height) # will just be one cluster if height > max_height
            
        } else if (partition_method == 'qgamma') {

            # library(fitdistrplus)
            gamma_fit = fitdist(heights, 'gamma')
            shape = gamma_fit$estimate[1]
            rate = gamma_fit$estimate[2]
            cut_height=qgamma(p=1-p_val, shape=shape, rate=rate)
            flog.info(sprintf("cut height based on p_val(%g) = %g and partition_method: %s", p_val, cut_height, partition_method))
            grps <- cutree(hc, h=cut_height) # will just be one cluster if height > max_height
            
        #} else if (partition_method == 'shc') {
        #    
        #    grps <- .get_shc_clusters(tumor_expr_data, hclust_method, p_val)
            
        } else if (partition_method == 'none') {
            
            grps <- cutree(hc, k=1)
            
        } else {
            stop("Error, not recognizing parition_method")
        }
        
        # cluster_ids = unique(grps)
        # flog.info(sprintf("cut tree into: %g groups", length(cluster_ids)))
        
        tumor_subcluster_info$subclusters = list()
        
        ordered_idx = tumor_group_idx[hc$order]
        s = split(grps,grps)
        flog.info(sprintf("cut tree into: %g groups", length(s)))

        start_idx = 1

        # for (g in cluster_ids) {
        for (g in names(s)) {
            
            split_subcluster = paste0(tumor_name, "_s", g)
            flog.info(sprintf("-processing %s,%s", tumor_name, split_subcluster))
            
            # subcluster_indices = tumor_group_idx[which(grps == g)]
            end_idx = start_idx + length(s[[g]]) - 1
            subcluster_indices = tumor_group_idx[hc$order[start_idx:end_idx]]
            start_idx = end_idx + 1
            
            tumor_subcluster_info$subclusters[[ split_subcluster ]] = subcluster_indices
        }
    }
    else {
        tumor_subcluster_info$hc = NULL # can't make hc with a single element, even manually, need to have workaround in plotting step
        tumor_subcluster_info$subclusters[[paste0(tumor_name, "_s1") ]] = tumor_group_idx
    }
    
    return(tumor_subcluster_info)
}


#.get_shc_clusters <- function(tumor_expr_data, hclust_method, p_val) { 
#
# library(sigclust2)
#    
#    flog.info(sprintf("defining groups using shc, hclust_method: %s, p_val: %g", hclust_method, p_val))
#    
#    shc_result = sigclust2::shc(t(tumor_expr_data), metric='euclidean', linkage=hclust_method, alpha=p_val)
#
#    cluster_idx = which(shc_result$p_norm <= p_val)
#        
#    grps = rep(1, ncol(tumor_expr_data))
#    names(grps) <- colnames(tumor_expr_data)
#    
#    counter = 1
#    for (cluster_id in cluster_idx) {
#        labelsA = unlist(shc_result$idx_hc[cluster_id,1])
#
#        labelsB = unlist(shc_result$idx_hc[cluster_id,2])
#
#        counter = counter + 1
#        grps[labelsB] <- counter
#    }
#    
#    return(grps)
#}
        



.find_DE_stat_significance <- function(normal_matrix, tumor_matrix) {
    
    run_t_test<- function(idx) {
        vals1 = unlist(normal_matrix[idx,,drop=TRUE])
        vals2 = unlist(tumor_matrix[idx,,drop=TRUE])
        
        ## useful way of handling tests that may fail:
        ## https://stat.ethz.ch/pipermail/r-help/2008-February/154167.html

        res = try(t.test(vals1, vals2), silent=TRUE)
        
        if (is(res, "try-error")) return(NA) else return(res$p.value)
        
    }

    pvals = sapply(seq(nrow(normal_matrix)), run_t_test)

    return(pvals)
}




##### Below is deprecated.... use inferCNV_tumor_subclusters.random_smoothed_trees
## Random Trees

.partition_by_random_trees <- function(tumor_name, tumor_expr_data, hclust_method, p_val) {

    grps <- rep(sprintf("%s.%d", tumor_name, 1), ncol(tumor_expr_data))
    names(grps) <- colnames(tumor_expr_data)

    grps <- .single_tumor_subclustering_recursive_random_trees(tumor_expr_data, hclust_method, p_val, grps)

    
    return(grps)

}


.single_tumor_subclustering_recursive_random_trees <- function(tumor_expr_data, hclust_method, p_val, grps.adj, min_cluster_size_recurse=10) {

    tumor_clade_name = unique(grps.adj[names(grps.adj) %in% colnames(tumor_expr_data)])
    message("unique tumor clade name: ", tumor_clade_name)
    if (length(tumor_clade_name) > 1) {
        stop("Error, found too many names in current clade")
    }
    
    hc <- hclust(parallelDist(t(tumor_expr_data), threads=infercnv.env$GLOBAL_NUM_THREADS), method=hclust_method)

    rand_params_info = .parameterize_random_cluster_heights(tumor_expr_data, hclust_method)

    h_obs = rand_params_info$h_obs
    h = h_obs$height
    max_height = rand_params_info$max_h
    
    max_height_pval = 1
    if (max_height > 0) {
        ## important... as some clades can be fully collapsed (all identical entries) with zero heights for all
        e = rand_params_info$ecdf
        max_height_pval = 1- e(max_height)
    }

    #message(sprintf("Lengths(h): %s", paste(h, sep=",", collapse=",")))
    #message(sprintf("max_height_pval: %g", max_height_pval))
    
    if (max_height_pval <= p_val) {
        ## keep on cutting.
        cut_height = mean(c(h[length(h)], h[length(h)-1]))
        message(sprintf("cutting at height: %g",  cut_height))
        grps = cutree(h_obs, h=cut_height)
        print(grps)
        uniqgrps = unique(grps)
        
        message("unique grps: ", paste0(uniqgrps, sep=",", collapse=","))
        for (grp in uniqgrps) {
            grp_idx = which(grps==grp)
            
            message(sprintf("grp: %s  contains idx: %s", grp, paste(grp_idx,sep=",", collapse=","))) 
            df = tumor_expr_data[,grp_idx,drop=FALSE]
            ## define subset.
            subset_cell_names = colnames(df)
            
            subset_clade_name = sprintf("%s.%d", tumor_clade_name, grp)
            grps.adj[names(grps.adj) %in% subset_cell_names] <- subset_clade_name

            if (length(grp_idx) > min_cluster_size_recurse) {
                ## recurse
                grps.adj <- .single_tumor_subclustering_recursive_random_trees(tumor_expr_data=df,
                                                                               hclust_method=hclust_method,
                                                                               p_val=p_val,
                                                                               grps.adj)
            } else {
                message("paritioned cluster size too small to recurse further")
            }
        }
    } else {
        message("No cluster pruning: ", tumor_clade_name)
    }
    
    return(grps.adj)
}


.parameterize_random_cluster_heights <- function(expr_matrix, hclust_method, plot=TRUE) {
    
    ## inspired by: https://www.frontiersin.org/articles/10.3389/fgene.2016.00144/full

    t_tumor.expr.data = t(expr_matrix) # cells as rows, genes as cols
    d = parallelDist(t_tumor.expr.data, threads=infercnv.env$GLOBAL_NUM_THREADS)

    h_obs = hclust(d, method=hclust_method)

        
    # permute by chromosomes
    permute_col_vals <- function(df) {

        num_cells = nrow(df)

        for (i in seq(ncol(df) ) ) {
            
            df[, i] = df[sample(x=seq_len(num_cells), size=num_cells, replace=FALSE), i]
        }
        
        df
    }
    
    h_rand_ex = NULL
    max_rand_heights = c()
    num_rand_iters=100
    for (i in seq_len(num_rand_iters)) {
        #message(sprintf("iter i:%d", i))
        rand.tumor.expr.data = permute_col_vals(t_tumor.expr.data)
        
        rand.dist = parallelDist(rand.tumor.expr.data, threads=infercnv.env$GLOBAL_NUM_THREADS)
        h_rand <- hclust(rand.dist, method=hclust_method)
        h_rand_ex = h_rand
        max_rand_heights = c(max_rand_heights, max(h_rand$height))
    }
    
    h = h_obs$height

    max_height = max(h)
    
    message(sprintf("Lengths for original tree branches (h): %s", paste(h, sep=",", collapse=",")))
    message(sprintf("Max height: %g", max_height))

    message(sprintf("Lengths for max heights: %s", paste(max_rand_heights, sep=",", collapse=",")))
    
    e = ecdf(max_rand_heights)
    
    pval = 1- e(max_height)
    message(sprintf("pval: %g", pval))
    
    params_list <- list(h_obs=h_obs,
                        max_h=max_height,
                        rand_max_height_dist=max_rand_heights,
                        ecdf=e,
                        h_rand_ex = h_rand_ex
                        )
    
    if (plot) {
        .plot_tree_height_dist(params_list)
    }
    
    
    return(params_list)
    
}


.plot_tree_height_dist <- function(params_list, plot_title='tree_heights') {

    mf = par(mfrow=(c(3,1)))

    ## density plot
    rand_height_density = density(params_list$rand_max_height_dist)
    
    xlim=range(params_list$max_h, rand_height_density$x)
    ylim=range(rand_height_density$y)
    plot(rand_height_density, xlim=xlim, ylim=ylim, main=paste(plot_title, "density"))
    abline(v=params_list$max_h, col='red')

        
    ## plot the clustering
    h_obs = params_list$h_obs
    h_obs$labels <- NULL #because they're too long to display
    plot(h_obs)
    
    ## plot a random example:
    h_rand_ex = params_list$h_rand_ex
    h_rand_ex$labels <- NULL
    plot(h_rand_ex)
            
    par(mf)
        
}

.get_tree_height_via_ecdf <- function(p_val, params_list) {
    
    h = quantile(params_list$ecdf, probs=1-p_val)

    return(h)
}


.single_tumor_leiden_subclustering <- function(tumor_group, tumor_group_idx, tumor_expr_data, chrs, k_nn, leiden_resolution, leiden_method, leiden_function, hclust_method) {
    res = list()
    res$subclusters = list()

    if (length(tumor_group_idx) < 3) {
        flog.info(paste0("Too few cells in group ", tumor_group, " for any (sub)clustering. Keeping as is."))
        res$hc = NULL # can't make hc with a single element, even manually, need to have workaround in plotting step
        res$subclusters[[paste0(tumor_group, "_s1") ]] = tumor_group_idx
        return(res)
    }
    if (k_nn >= length(tumor_group_idx)) {
        flog.info(paste0("Less cells in group ", tumor_group, " than k_nn setting. Keeping as a single subcluster."))
        res$subclusters[[ tumor_group ]] = tumor_group_idx
        res$hc = hclust(parallelDist(t(tumor_expr_data), threads=infercnv.env$GLOBAL_NUM_THREADS), method=hclust_method)
        return(res)
    }

    # if (leiden_method == "intersect_chr") {
    #     partition = NULL
    #     for (c in unique(chrs)) {
    #         c_data = tumor_expr_data[which(chrs == c), , drop=FALSE]
    #         c_snn = nn2(t(c_data), k=k_nn)$nn.idx
    #         c_sparse_adjacency_matrix <- sparseMatrix(
    #             i = rep(seq_len(ncol(tumor_expr_data)), each=k_nn), 
    #             j = t(c_snn),
    #             x = rep(1, ncol(tumor_expr_data) * k_nn),
    #             dims = c(ncol(tumor_expr_data), ncol(tumor_expr_data)),
    #             dimnames = list(colnames(tumor_expr_data), colnames(tumor_expr_data))
    #         )
    #         c_graph_obj = graph_from_adjacency_matrix(c_sparse_adjacency_matrix, mode="undirected")
    #         c_partition_obj = cluster_leiden(c_graph_obj, resolution_parameter=leiden_resolution)
    #         partition = paste(partition, c_partition_obj$membership)
    #     }

    #     flog.info(paste0("Group ", tumor_group, " was subdivided into ", length(unique(partition)), " clusters."))
    # }
    # else if (leiden_method == "per_chr") {
    #     combined_snn = NULL
    #     for (c in unique(chrs)) {
    #         c_data = tumor_expr_data[which(chrs == c), , drop=FALSE]
    #         c_snn = nn2(t(c_data), k=k_nn)$nn.idx
    #         combined_snn = cbind(combined_snn, c_snn)
    #     }

    #     snn_table = apply(combined_snn, 1, table, simplify=FALSE)
    #     snn_table_lengths = lapply(snn_table, length)
    #     snn_neighbors = as.integer(names(unlist(snn_table)))
    #     snn_weights = unlist(snn_table)
    #     # rep(seq_len(ncol(tumor_expr_data)), times=snn_table_lengths)

    #     sparse_adjacency_matrix <- sparseMatrix(
    #         i = rep(seq_len(ncol(tumor_expr_data)), times=snn_table_lengths),
    #         j = snn_neighbors,
    #         x = snn_weights,
    #         dims = c(ncol(tumor_expr_data), ncol(tumor_expr_data)),
    #         dimnames = list(colnames(tumor_expr_data), colnames(tumor_expr_data))
    #     )

    #     graph_obj = graph_from_adjacency_matrix(sparse_adjacency_matrix, mode="min", weighted=TRUE)
    #     partition_obj = cluster_leiden(graph_obj, resolution_parameter=leiden_resolution)
    #     partition = partition_obj$membership

    #     flog.info(paste0("Group ", tumor_group, " was subdivided into ", partition_obj$nb_clusters, 
    #        " clusters with a partition quality score of ", partition_obj$quality))
    # }
    # else if (leiden_method == "per_chr_dist") {
    #     combined_snn_idx = NULL
    #     combined_snn_dist = NULL
    #     for (c in unique(chrs)) {
    #         c_data = tumor_expr_data[which(chrs == c), , drop=FALSE]
    #         c_snn = nn2(t(c_data), k=k_nn)
    #         combined_snn_idx = cbind(combined_snn_idx, c_snn$nn.idx[, 2:ncol(c_snn$nn.idx)])
    #         combined_snn_dist = cbind(combined_snn_dist, c_snn$nn.dists[, 2:ncol(c_snn$nn.dist)])
    #     }
        
    #     #combined_snn_dist = ceiling(max(combined_snn_dist)) - combined_snn_dist
    #     combined_snn_dist = 2 - combined_snn_dist
    #     combined_snn_dist[which(combined_snn_dist < 0)] = 0


    #     snn_table = apply(combined_snn_idx, 1, table, simplify=FALSE)
    #     snn_order = apply(combined_snn_dist, 1, order, simplify=FALSE)
    #     snn_table_lengths = lapply(snn_table, length)
    #     snn_neighbors = as.integer(names(unlist(snn_table)))

    #     snn_weights = vector(mode="double", length=length(snn_neighbors))

    #     # apply(combined_snn_idx, order, simplify=FALSE)

    #     k = 1
    #     for (cell in seq_len(nrow(combined_snn_dist))) {
    #         j = 1
    #         for (i in seq_len(length(snn_table[[cell]]))) {
    #             #which(snn_order == names(snn_table)[i])
    #             snn_weights[k] = sum(combined_snn_dist[cell , snn_order[[cell]][j:(j + snn_table[[cell]][i] - 1 )]])
    #             k = k + 1
    #             j = j + snn_table[[cell]][i]
    #         }
    #     }

    #     sparse_adjacency_matrix <- sparseMatrix(
    #         i = rep(seq_len(ncol(tumor_expr_data)), times=snn_table_lengths),
    #         j = snn_neighbors,
    #         x = snn_weights,
    #         dims = c(ncol(tumor_expr_data), ncol(tumor_expr_data)),
    #         dimnames = list(colnames(tumor_expr_data), colnames(tumor_expr_data))
    #     )

    #     graph_obj = graph_from_adjacency_matrix(sparse_adjacency_matrix, mode="min", weighted=TRUE)
    #     partition_obj = cluster_leiden(graph_obj, resolution_parameter=NULL)#leiden_resolution)
    #     partition = partition_obj$membership

    #     flog.info(paste0("Group ", tumor_group, " was subdivided into ", partition_obj$nb_clusters, 
    #        " clusters with a partition quality score of ", partition_obj$quality))
    # }
    # else if (leiden_method == "per_select_chr") {
    #     combined_snn = NULL
    #     for (c in select_chr) {
    #         c_data = tumor_expr_data[which(chrs == c), , drop=FALSE]
    #         c_snn = nn2(t(c_data), k=k_nn)$nn.idx
    #         combined_snn = cbind(combined_snn, c_snn)#[, 2:ncol(c_snn)])
    #     }

    #     snn_table = apply(combined_snn, 1, table, simplify=FALSE)
    #     snn_table_lengths = lapply(snn_table, length)
    #     snn_weights = unlist(snn_table)
    #     snn_neighbors = as.integer(names(snn_weights))
        
    #     # rep(seq_len(ncol(tumor_expr_data)), times=snn_table_lengths)

    #     sparse_adjacency_matrix <- sparseMatrix(
    #         i = rep(seq_len(ncol(tumor_expr_data)), times=snn_table_lengths),
    #         j = snn_neighbors,
    #         x = snn_weights,
    #         dims = c(ncol(tumor_expr_data), ncol(tumor_expr_data)),
    #         dimnames = list(colnames(tumor_expr_data), colnames(tumor_expr_data))
    #     )

    #     graph_obj = graph_from_adjacency_matrix(sparse_adjacency_matrix, mode="min", weighted=TRUE)
    #     partition_obj = cluster_leiden(graph_obj, resolution_parameter=NULL)#leiden_resolution)
    #     partition = partition_obj$membership

    #     flog.info(paste0("Group ", tumor_group, " was subdivided into ", partition_obj$nb_clusters, 
    #        " clusters with a partition quality score of ", partition_obj$quality))
    # }
    # else if (leiden_method == "seurat") {
    #     snn_seurat = Seurat::FindNeighbors(t(tumor_expr_data), k.param=k_nn)
    #     graph_obj = graph_from_adjacency_matrix(snn_seurat$snn, mode="min", weighted=TRUE)
    #     # igraph::plot.igraph(graph_obj)
    #     partition_obj = cluster_leiden(graph_obj, resolution_parameter=leiden_resolution)
    #     partition = partition_obj$membership
    # }
    if (leiden_method == "PCA") {
        # seurat_obs = CreateSeuratObject(tumor_expr_data, "assay" = "infercnv", project = "infercnv", names.field = 1)
        # seurat_obs = FindVariableFeatures(seurat_obs) # , selection.method = "vst", nfeatures = 2000

        # all.genes <- rownames(seurat_obs)
        # seurat_obs <- ScaleData(seurat_obs, features = all.genes)

        # seurat_obs = RunPCA(seurat_obs)
        # seurat_obs = FindNeighbors(seurat_obs, k.param=k_nn)

        # graph_obj = graph_from_adjacency_matrix(seurat_obs@graphs$infercnv_snn, mode="min", weighted=TRUE)
        # partition_obj = cluster_leiden(graph_obj, resolution_parameter=leiden_resolution, objective_function=leiden_function)
        # partition = partition_obj$membership
        partition = .leiden_seurat_preprocess_routine(expr_data=tumor_expr_data, k_nn=k_nn, resolution_parameter=leiden_resolution, objective_function=leiden_function)
    }
    else { # "simple"
        snn <- nn2(t(tumor_expr_data), k=k_nn)$nn.idx

        sparse_adjacency_matrix <- sparseMatrix(
           i = rep(seq_len(ncol(tumor_expr_data)), each=k_nn), 
           j = t(snn),
           x = rep(1, ncol(tumor_expr_data) * k_nn),
           dims = c(ncol(tumor_expr_data), ncol(tumor_expr_data)),
           dimnames = list(colnames(tumor_expr_data), colnames(tumor_expr_data))
        )
        
        graph_obj = graph_from_adjacency_matrix(sparse_adjacency_matrix, mode="undirected")
        partition_obj = cluster_leiden(graph_obj, resolution_parameter=leiden_resolution, objective_function=leiden_function)
        partition = partition_obj$membership

        #flog.info(paste0("Group ", tumor_group, " was subdivided into ", partition_obj$nb_clusters, 
        #   " clusters with a partition quality score of ", partition_obj$quality))

        #flog.info("If this score is too low and you observe too much fragmentation, try decreasing the leiden resolution parameter")
        #flog.info("If this score is too low and you observe clusters that are still too diverse, try increasing the leiden resolution parameter")

        #subcluster_graph = igraph::graph_from_adj_list(snn, mode="all")
        #tst2 =igraph::cluster_leiden(subcluster_graph)

        #partition = leiden(sparse_adjacency_matrix, resolution_parameter=leiden_resolution)    
    }

    # adjacency_matrix <- matrix(0L, ncol(tumor_expr_data), ncol(tumor_expr_data))
    # rownames(adjacency_matrix) <- colnames(adjacency_matrix) <- colnames(tumor_expr_data)
    # for(ii in seq_len(ncol(tumor_expr_data))) {
    #     adjacency_matrix[ii, colnames(tumor_expr_data)[snn[ii, ]]] <- 1L
    # }
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    
    # check that rows add to k_nn
    # sum(adjacency_matrix[1,]) == k_nn
    # table(apply(adjacency_matrix, 1, sum))
    # partition <- leiden(adjacency_matrix, resolution_parameter=leiden_resolution)

    tmp_full_phylo = NULL
    added_height = 1
    # find a way to sort partition by size to make sure not to start with a single cell partition
    for (i in unique(partition[grouping(partition)])) {  # grouping() is there to make sure we do not start looking at a one cell cluster since it cannot be added to a phylo object
        res$subclusters[[ paste(tumor_group, i, sep="_s") ]] = tumor_group_idx[which(partition == i)]  # this should transfer names as well
        # names(res$subclusters[[ paste(tumor_group, i, sep="_s") ]]) = tumor_group_idx[which(partition == i)]

        if (length(which(partition == i)) >= 2) {
            tmp_phylo = as.phylo(hclust(parallelDist(t(tumor_expr_data[, which(partition == i), drop=FALSE]), threads=infercnv.env$GLOBAL_NUM_THREADS), method=hclust_method))

            if (is.null(tmp_full_phylo)) {
                tmp_full_phylo = tmp_phylo
            }
            else {
                height1 = get.rooted.tree.height(tmp_phylo)
                height2 = get.rooted.tree.height(tmp_full_phylo)

                if (height1 == height2) {
                     tmp_phylo$root.edge = added_height
                     tmp_full_phylo$root.edge = added_height
                }
                else if (height1 > height2) {
                     tmp_phylo$root.edge = added_height
                     tmp_full_phylo$root.edge = height1 - height2 + added_height
                }
                else {  # height2 > height1
                     tmp_phylo$root.edge = height2 - height1 + added_height
                     tmp_full_phylo$root.edge = added_height
                }

                tmp_full_phylo = tmp_phylo + tmp_full_phylo  # x + y is a shortcut for: bind.tree(x, y, position = if (is.null(x$root.edge)) 0 else x$root.edge)
            }
        }
        else {  # ==1
            tmp_full_phylo = add_single_branch_to_phylo(tmp_full_phylo, colnames(tumor_expr_data)[which(partition == i)])
        }
    }

    # as.hclust(merge(merge(as.dendrogram(subclust_obj@tumor_subclusters$hc$`all_observations`), as.dendrogram(subclust_obj@tumor_subclusters$hc$`Microglia/Macrophage`)), as.dendrogram(subclust_obj@tumor_subclusters$hc$`Oligodendrocytes (non-malignant)`)))
    res$hc = as.hclust(tmp_full_phylo)

    return(res)
}


.whole_dataset_leiden_subclustering_per_chr <- function(expr_data, chrs, k_nn, leiden_resolution, leiden_function) {
    # z score filtering over all the data based on refs, done in calling method

    # subclusters_per_chr = vector(mode="list", length=length(unique(chrs)))
    subclusters_per_chr = list()
    
    # per_chr_partition = vector(mode="list", length=length(unique(chrs)))

    for (c in unique(chrs)) {

        c_data = expr_data[which(chrs == c), , drop=FALSE]

        partition = .leiden_seurat_preprocess_routine(expr_data=c_data, k_nn=k_nn, resolution_parameter=leiden_resolution, objective_function=leiden_function)

        # seurat_obs = CreateSeuratObject(c_data, "assay" = "infercnv", project = "infercnv", names.field = 1)
        # seurat_obs = FindVariableFeatures(seurat_obs) # , selection.method = "vst", nfeatures = 2000

        # all.genes <- rownames(seurat_obs)
        # seurat_obs <- ScaleData(seurat_obs, features = all.genes)

        # seurat_obs = RunPCA(seurat_obs)
        # seurat_obs = FindNeighbors(seurat_obs, k.param=k_nn)

        # graph_obj = graph_from_adjacency_matrix(seurat_obs@graphs$infercnv_snn, mode="min", weighted=TRUE)
        # partition_obj = cluster_leiden(graph_obj, resolution_parameter=(leiden_resolution/10))
        # partition = partition_obj$membership

        subclusters_per_chr[[c]] = list()
        # no HClust on these subclusters as they may mix both ref and obs cells
        for (i in unique(partition[grouping(partition)])) {  # grouping() is there to make sure we do not start looking at a one cell cluster since it cannot be added to a phylo object
            subclusters_per_chr[[c]][[ paste("all_cells", i, sep="_s") ]] = which(partition == i)
            names(subclusters_per_chr[[c]][[ paste("all_cells", i, sep="_s") ]]) = colnames(c_data)[which(partition == i)]
        }
    }

    return(subclusters_per_chr)
}

.leiden_seurat_preprocess_routine <- function(expr_data, k_nn, resolution_parameter, objective_function) {
    seurat_obs = CreateSeuratObject(expr_data, "assay" = "infercnv", project = "infercnv", names.field = 1)
    seurat_obs = FindVariableFeatures(seurat_obs) # , selection.method = "vst", nfeatures = 2000

    all.genes <- rownames(seurat_obs)
    seurat_obs <- ScaleData(seurat_obs, features = all.genes)

    seurat_obs = RunPCA(seurat_obs, npcs=10) # only settings dims to 10 since FindNeighbors only uses 1:10 by default, if needed, could add optional settings for npcs and dims
    seurat_obs = FindNeighbors(seurat_obs, k.param=k_nn)

    graph_obj = graph_from_adjacency_matrix(seurat_obs@graphs$infercnv_snn, mode="min", weighted=TRUE)
    partition_obj = cluster_leiden(graph_obj, resolution_parameter=resolution_parameter, objective_function=objective_function)
    partition = partition_obj$membership

    return(partition)
}

add_single_branch_to_phylo = function(in_tree, label) {
    in_root_height = get.rooted.tree.height(in_tree)

    n_tips = length(in_tree$tip.label)

    tip_nodes = which(in_tree$edge <= n_tips)
    internal_nodes = which(in_tree$edge > n_tips)

    # update the existing list of internal node splits to make space for the new top branching
    in_tree$edge[tip_nodes] = in_tree$edge[tip_nodes] + 1
    in_tree$edge[internal_nodes] = in_tree$edge[internal_nodes] + 2

    # update the existing list of internal nodes to add the new top branching
    in_tree$edge = rbind(c(n_tips + 2, n_tips + 3), in_tree$edge)
    in_tree$edge = rbind(c(n_tips + 2, 1), in_tree$edge)

    # update the internal nodes count
    in_tree$Nnode = in_tree$Nnode + 1

    # add the heights of the 2 new branches from the new top branching
    root_height = 1
    if (!is.null(in_tree$root.edge)) {
        root_height = in_tree$root.edge
    }
    in_tree$edge.length = c(in_root_height + root_height, root_height, in_tree$edge.length)

    # update the list of tip labels
    in_tree$tip.label = c(label, in_tree$tip.label)

    return(in_tree)
}

