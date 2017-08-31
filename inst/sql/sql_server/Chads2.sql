IF OBJECT_ID('tempdb..#chads2_concepts', 'U') IS NOT NULL
  DROP TABLE #chads2_concepts;

CREATE TABLE #chads2_concepts (
	diag_category_id INT,
	concept_id INT
	);

IF OBJECT_ID('tempdb..#chads2_scoring', 'U') IS NOT NULL
	DROP TABLE #chads2_scoring;

CREATE TABLE #chads2_scoring (
	diag_category_id INT,
	diag_category_name VARCHAR(255),
	weight INT
	);

--Congestive heart failure
INSERT INTO #chads2_scoring (diag_category_id,diag_category_name,weight)
VALUES (1,'Congestive heart failure',1);

INSERT INTO #chads2_concepts (diag_category_id,concept_id)
SELECT 1, descendant_concept_id
FROM @cdm_database_schema.concept_ancestor
WHERE ancestor_concept_id in (316139)
;

--Hypertension
INSERT INTO #chads2_scoring (diag_category_id,diag_category_name,weight)
VALUES (2,'Hypertension',1);

INSERT INTO #chads2_concepts (diag_category_id,concept_id)
SELECT 2, descendant_concept_id
FROM @cdm_database_schema.concept_ancestor
WHERE ancestor_concept_id in (316866)
;

--Age > 75
INSERT INTO #chads2_scoring (diag_category_id,diag_category_name,weight)
VALUES (3,'Age>75',1);

--no codes

--Diabetes
INSERT INTO #chads2_scoring (diag_category_id,diag_category_name,weight)
VALUES (4,'Diabetes',1);

INSERT INTO #chads2_concepts (diag_category_id,concept_id)
SELECT 4, descendant_concept_id
FROM @cdm_database_schema.concept_ancestor
WHERE ancestor_concept_id in (201820)
;

--Stroke
INSERT INTO #chads2_scoring (diag_category_id,diag_category_name,weight)
VALUES (5,'Stroke',2);

INSERT INTO #chads2_concepts (diag_category_id,concept_id)
SELECT 5, descendant_concept_id
FROM @cdm_database_schema.concept_ancestor
WHERE ancestor_concept_id in (381591, 434056)
;


-- Feature construction
WITH rawData (
{@aggregated} ? {
	subject_id,
	cohort_start_date,
} : {
	row_id,
}
	score
	)
AS (
	SELECT 
{@aggregated} ? {
		subject_id,
		cohort_start_date,
} : {
		row_id,
}
		SUM(weight) AS score
	FROM (
		SELECT DISTINCT chads2_scoring.diag_category_id,
			chads2_scoring.weight,
{@aggregated} ? {
			cohort.subject_id,
			cohort.cohort_start_date
} : {
			cohort.@row_id_field AS row_id
}			
		FROM @cohort_table cohort
		INNER JOIN @cdm_database_schema.condition_era condition_era
			ON cohort.subject_id = condition_era.person_id
		INNER JOIN #chads2_concepts chads2_concepts
			ON condition_era.condition_concept_id = chads2_concepts.concept_id
		INNER JOIN #chads2_scoring chads2_scoring
			ON chads2_concepts.diag_category_id = chads2_scoring.diag_category_id
{@temporal} ? {		
		WHERE condition_era_start_date <= cohort.cohort_start_date
} : {
		WHERE condition_era_start_date <= DATEADD(DAY, @end_day, cohort.cohort_start_date)
}
{@cohort_definition_id != -1} ? {		AND cohort.cohort_definition_id = @cohort_definition_id}
	) temp
{@aggregated} ? {
	GROUP BY subject_id,
			cohort_start_date
} : {
	GROUP BY row_id
}	
)
{@aggregated} ? {
, overallStats (
	min_value,
	max_value,
	average_value,
	standard_deviation,
	count_value,
	count_no_value,
	population_size
	)
AS (
	SELECT CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM @cohort_table {@cohort_definition_id != -1} ? {WHERE cohort_definition_id = @cohort_definition_id}) THEN MIN(score) ELSE 0 END AS min_value,
		MAX(score) AS max_value,
		SUM(score) / (1.0 * (SELECT COUNT(*) FROM @cohort_table {@cohort_definition_id != -1} ? {WHERE cohort_definition_id = @cohort_definition_id})) AS average_value,
		SQRT((1.0 * COUNT(*)*SUM(score * score) - 1.0 * SUM(score)*SUM(score)) / (1.0 * COUNT(*)*(1.0 * COUNT(*) - 1)))  AS standard_deviation,
		COUNT(*) AS count_value,
		(SELECT COUNT(*) FROM @cohort_table {@cohort_definition_id != -1} ? {WHERE cohort_definition_id = @cohort_definition_id}) - COUNT(*) AS count_no_value,
		(SELECT COUNT(*) FROM @cohort_table {@cohort_definition_id != -1} ? {WHERE cohort_definition_id = @cohort_definition_id}) AS population_size
	FROM rawData
	),
prepStats (
	score,
	total,
	rn
	)
AS (
	SELECT score,
		COUNT(*) AS total,
		ROW_NUMBER() OVER (
			ORDER BY score
			) AS rn
	FROM rawData
	GROUP BY score
	),
prepStats2 (
	score,
	total,
	accumulated
	)
AS (
	SELECT s.score,
		s.total,
		SUM(p.total) AS accumulated
	FROM prepStats s
	INNER JOIN prepStats p
		ON p.rn <= s.rn
	GROUP BY s.score,
		s.total,
		s.rn
	)
SELECT 1000 + @analysis_id AS covariate_id,
{@temporal} ? {
    NULL AS time_id,
}
	o.count_value,
	o.min_value,
	o.max_value,
	o.average_value,
	o.standard_deviation,
	CASE 
		WHEN .50 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .50 * o.population_size THEN score	END) 
		END AS median_value,
	CASE 
		WHEN .10 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .10 * o.population_size THEN score	END) 
		END AS p10_value,		
	CASE 
		WHEN .25 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .25 * o.population_size THEN score	END) 
		END AS p25_value,	
	CASE 
		WHEN .75 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .75 * o.population_size THEN score	END) 
		END AS p75_value,	
	CASE 
		WHEN .90 * o.population_size < count_no_value THEN 0
		ELSE MIN(CASE WHEN p.accumulated + count_no_value >= .90 * o.population_size THEN score	END) 
		END AS p90_value		
INTO @covariate_table
FROM prepStats2 p
CROSS JOIN overallStats o
{@included_cov_table != ''} ? {WHERE 1000 + @analysis_id IN (SELECT id FROM @included_cov_table)}
GROUP BY o.count_value,
	o.count_no_value,
	o.min_value,
	o.max_value,
	o.average_value,
	o.standard_deviation,
	o.population_size;
} : {
SELECT 1000 + @analysis_id AS covariate_id,
{@temporal} ? {
    NULL AS time_id,
}	
	row_id,
	score AS covariate_value 
INTO @covariate_table
FROM rawData
{@included_cov_table != ''} ? {WHERE 1000 + @analysis_id IN (SELECT id FROM @included_cov_table)}
;
}

TRUNCATE TABLE #chads2_concepts;

DROP TABLE #chads2_concepts;

TRUNCATE TABLE #chads2_scoring;

DROP TABLE #chads2_scoring;

-- Reference construction
INSERT INTO #cov_ref (
	covariate_id,
	covariate_name,
	analysis_id,
	concept_id
	)
SELECT covariate_id,
	'CHADS2' AS covariate_name,
	@analysis_id AS analysis_id,
	0 AS concept_id
FROM (
	SELECT DISTINCT covariate_id
	FROM @covariate_table
	) t1;
	
INSERT INTO #analysis_ref (
	analysis_id,
	analysis_name,
	domain_id,
{!@temporal} ? {
	start_day,
	end_day,
}
	is_binary,
	missing_means_zero
	)
SELECT @analysis_id AS analysis_id,
	'@analysis_name' AS analysis_name,
	'@domain_id' AS domain_id,
{!@temporal} ? {
	NULL AS start_day,
	@end_day AS end_day,
}
	'N' AS is_binary,
	'Y' AS missing_means_zero;
