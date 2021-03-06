#! /usr/bin/env Rscript

# File description -------------------------------------------------------------
# This file contains utilities for plotting income at different
# households. These were used for the call with Sedesol on June 29,
# 2016, see income_vis.R for the actual application of these functions.


# Code Block -------------------------------------------------------------------

#' @title Get a list of homes contained in a list of localities
#' @param conn [dplyr db connection] A dplyr connection to a postgres database.
#' This can be generated by calling db_conn() in db_conn.R for example.
#' @param locality_ids [vector of strings] A vector of locality ids from which
#' to extract data from the database.
#' @return [vector] A vector of id_mdm_h household ids for homes contained in
#' the specified locliaites.
homes_for_localidad <- function(db_conn, locality_ids) {
  # filter will fail if not vector length >= 2
  if (length(locality_ids) == 1) {
    locality_ids <- c(locality_ids, locality_ids)
  }

  tbl(conn, "cuis_domicilio") %>%
    filter(cve_localidad %in% locality_ids) %>%
    select(id_mdm_h) %>%
    as.data.table() %>%
    unlist(use.names = FALSE)
}

#' @title Extract a data.table from a postgres connection
#' @param db_conn [dplyr db connection] A dplyr connection to a postgres
#' database. This can be generated by calling db_conn() in db_conn.R for
#' example.
#' @param table_name [string] The name of the table from which to extract data
#' from the database.
#' @param home_ids [vector of strings] A vector of id_mdm_h's from which
#' to extract data from the database.
#' @return  [data table] A data.table giving rows from the table_name data
#' in the database corresponding to the homes in home_ids.
data_for_homes <- function(conn, table_name, home_ids) {
  data_conn <- tbl(conn, table_name)
  data_conn %>%
    filter(id_mdm_h %in% home_ids) %>%
    as.data.table()
}

#' @title Extract cuis, sifode, and imss data for a list of localities
#' @description Given database connections to the cuis domicilio, cuis se
#' integrante, and IMSS data, generate a data.tables giving data for these
#' localities.
#' @param conn [dplyr db connection] A dplyr connection to a postgres database.
#' This can be generated by calling db_conn() in db_conn.R for example.
#' @param locality_ids [vector of strings] A vector of locality ids from which
#' to extract data from the database.
#' @return [list of data.tables] A list containing income data for these
#' localities. Specifically, it has these components,
#'     (1) se_inte: The cuis_se_integral data for these localities
#'     (2) sifode_univ: The  sifode universal data these localities
#'     (3) imss: The imss data for these localities.
get_income_data <- function(conn, locality_ids) {
  home_ids <- homes_for_localidad(conn, locality_ids)

  se_inte <- data_for_homes(conn, "cuis_se_integrante", home_ids)
  sifode_univ <- data_for_homes(conn, "sifode_univ", home_ids)
  imss <- data_for_homes(conn, "imss_salario", home_ids)

  if (nrow(imss) > 0) {
    imss$salario_imss <- as.numeric(imss$salario_imss)
  }

  list(se_inte = se_inte, sifode_univ = sifode_univ, imss = imss)
}

#' @title Adjust self-reported incomes based on the c_periodo field
#' @description Some of the self-reported incomes are reported as being on
#' a daily, weekly, biweekly, or annual level. This function normalizes them
#' all to monthly level, assuming
#'     (1) If daily is reported, the person worked 20 days in the month
#'     (2) If weekly is reported, the person worked 4 weeks in the month
#'     (3) If biweekly is reported, the person worked 2 biweekly periods in
#'         the month.
#'     (4) If yearly is reported, the person earns 1 / 12 that amount each
#'         month.
#' @param incomes [numeric vector] A vector of incomes, possibly reported at
#' different periods.
#' @param periods [character vector] A vector describing the periods at which
#' each income is collected. "1" represents daily, "2" represents weekly, "3"
#' represents biweekly, "4" represents monthly, and "5" represents annually.
#' @return [vector numeric] A normalized vector of incomes at the monthly level.
adjust_income_periods <- function(incomes, periods) {
  adjust_fun <- function(incomes, periods, per_string, adjust_factor) {
    per_ix <- which(periods == per_string)
    incomes[per_ix] <- adjust_factor * incomes[per_ix]
    incomes
  }

  incomes <- adjust_fun(incomes, periods, "1", 20)
  incomes <- adjust_fun(incomes, periods, "2", 4)
  incomes <- adjust_fun(incomes, periods, "3", 2)
  incomes <- adjust_fun(incomes, periods, "4", 1)
  incomes <- adjust_fun(incomes, periods, "5", 1 / 12)
  incomes
}

#' @title Prepare the income data
#' @description This changes 99999 to NA, and normalizes incomes to monthly
#' periods.
#' @param incomes [numeric vector] A vector of incomes, possibly reported at
#' different periods.
#' @param periods [character vector] A vector describing the periods at which
#' each income is collected. "1" represents daily, "2" represents weekly, "3"
#' represents biweekly, "4" represents monthly, and "5" represents annually.
#' @return [vector numeric] A cleaned, normalized vector of incomes at the
#' monthly level.
setup_income_data <- function(incomes, periods) {
  incomes[incomes == "99999"] <- NA
  incomes <- as.numeric(incomes)
  adjust_income_periods(incomes, periods)
}

#' @title Prepare and merge income data
#' @param sifode_univ [data.table] A subset of the sifode_univ dataset,
#' containing the the estimated incomes.
#' @param se_int [data.table] A subset of the cuis_se_integrante dataset,
#' containing the self-reported incomes.
#' @param imss [data.table] A subset of the imss data set, containing the
#' imss data set.
#' @return [data.table] A data.table giving income at the household level,
#' from each of these data sources.
#'     (1) monto_sum is the sum of self-reported incomes within each household.
#'     (2) ingreso_pc is the constant value that the estimated incomes take
#'         within each household
#'     (3) ingreso_sum is ingreso_pc times the number of people in each
#'         household.
#'     (4) imss is the sum of imss incomes within each household.
merge_income_data <- function(sifode_univ, se_inte, imss) {
  # prepare income data
  months <- rep("4", nrow(sifode_univ))
  sifode_univ$ingreso_pc <- setup_income_data(sifode_univ$ingreso_pc, months)
  se_inte$monto <- setup_income_data(se_inte$monto, se_inte$c_periodo)
  se_inte$c_periodo <- as.numeric(se_inte$c_periodo)
  imss$salario_imss <- setup_income_data(imss$salario_imss,
                                         rep("1", nrow(imss)))

  # join the tables
  merged_incomes <- sifode_univ %>%
    left_join(se_inte) %>%
    left_join(imss) %>%
    group_by(id_mdm_h) %>%
    summarise(monto_sum = sum(monto, na.rm = TRUE),
              ingreso_pc = mean(ingreso_pc),
              ingreso_sum = sum(ingreso_pc),
              c_periodo = mean(c_periodo, na.rm = TRUE),
              imss = sum(salario_imss, na.rm = TRUE))

  # case that all imss values were missing, report NA
  merged_incomes[merged_incomes$imss == 0, "imss"] <- NA
  merged_incomes
}

#' @title Generate plots of the merged income data
#' @param income_data [data.table] A merged dataset giving incomes from
#' multiple sources. Specifically, we assume a data.table whose columns
#' are id_mdm_h (house id), monto_sum (sum of self-reported incomes within
#' a house), ingreso_pc (estimated incomes), ingreso_pc_sum (sum of estimated
#' incomes within the household level), c_periodo (the period of payment the
#' household reports for monto, on average), and imss (the imss estimated
#' incomes).
#' @param cur_id_mdm_h [vector or NULL] A vector giving id_mdm_h's points to
#' highlight as red points in the resulting figures.
#' @param x_jitter [scalar] The amount by which to jitter x-values in the
#' scatterplot of self-reported vs. estimated incomes.
#' @return A list of plots with the following interpretations,
#'     (1) A scatterplot of self-reported vs. ingreso_pc, with the specified
#'         cur_id_mdm_h's highlighted in red.
#'     (2) A scatterplot of self-reported vs. sum of ingreso_pc within
#'         households, with the specified cur_id_mdm_h's highlighted in red.
#'     (3) The analog of (1), faceted by period type.
#'     (4) The analog of (2), faceted by period type.
#'     (5) A histogram of incomes, across the current sources.
#'     (6) A histogram of incomes, across the sources, bur removing any zero
#'         self-reported incomes.
plot_merged_incomes <- function(income_data, cur_id_mdm_h = NULL,
                                x_jitter = 0) {
  p <- list()

  income_data$periodo_factor <- as.factor(round(income_data$c_periodo))
  p[[1]] <- ggplot() +
    geom_abline(slope = 1, alpha = 0.5) +
    geom_point(data = income_data,
               aes(x = log(1 + monto_sum, 10),
                   y = log(1 + ingreso_pc, 10),
                   col = periodo_factor),
               size = .5, alpha = 0.7,
               position = position_jitter(w = x_jitter)) +
    geom_point(data = income_data %>% filter(id_mdm_h %in% cur_id_mdm_h),
               aes(x = log(1 + monto_sum, 10),
                   y = log(1 + ingreso_pc, 10)),
               size = 2, col = "red") +
    scale_color_brewer(palette = "Set2") +
    guides(colour = guide_legend(override.aes = list(size = 3, alpha = 1))) +
    labs(x = "Reported income", y = "Estimated income", col = "Pay Period") +
    coord_fixed()

  p[[2]] <- ggplot() +
    geom_abline(slope = 1, alpha = 0.5) +
    geom_point(data = income_data,
               aes(x = log(1 + monto_sum, 10),
                   y = log(1 + ingreso_sum, 10),
                   col = periodo_factor),
               size = .5, alpha = 0.7,
               position = position_jitter(w = x_jitter)) +
    geom_point(data = income_data %>% filter(id_mdm_h %in% cur_id_mdm_h),
               aes(x = log(1 + monto_sum, 10),
                   y = log(1 + ingreso_pc, 10)),
               size = 2, col = "red") +
    scale_color_brewer(palette = "Set2") +
    guides(colour = guide_legend(override.aes = list(size = 3, alpha = 1))) +
    labs(x = "Reported income", y = "Estimated income", col = "Pay Period") +
    coord_fixed()

  p[[3]] <- p[[1]] +
    facet_wrap(~periodo_factor)

  p[[4]] <- p[[2]] +
    facet_wrap(~periodo_factor)

  m_income <- income_data %>%
    select(-c_periodo) %>%
    melt(variable.name = "source", value.name = "income")

  p[[5]] <- ggplot() +
    geom_histogram(data = m_income,
                   aes(x = log(1 + income, 10)), binwidth = .05) +
    geom_rug(data = m_income %>%
               filter(id_mdm_h %in% cur_id_mdm_h),
             aes(x = log(1 + income, 10)),
             col = "red", size = 2) +
    facet_grid(source ~ ., scale = "free_y")

  p[[6]] <- ggplot() +
    geom_histogram(data = m_income %>%
                     filter(income > 0),
                   aes(x = log(1 + income, 10)), binwidth = .05) +
    geom_rug(data = m_income %>%
               filter(id_mdm_h %in% cur_id_mdm_h),
             aes(x = log(1 + income, 10)),
             col = "red", size = 2) +
    facet_grid(source ~ ., scale = "free_y")

  p
}
