SET ANSI_NULLS ON
SET QUOTED_IDENTIFIER ON
IF NOT EXISTS (SELECT * FROM sysobjects WHERE id = object_id(N'[dbo].[Recommendations]')
AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
BEGIN
	CREATE TABLE [dbo].[Recommendations](
		[RecommendationId] [uniqueidentifier] NOT NULL DEFAULT NEWID(),
		[GeneratedDate] [datetime] NOT NULL,
		[Cloud] [varchar](20) NOT NULL,
		[Category] [varchar](50) NOT NULL,
		[ImpactedArea] [varchar](50) NOT NULL,
		[Impact] [varchar](20) NOT NULL,
		[RecommendationType] [varchar](50) NOT NULL,
		[RecommendationSubType] [varchar](50) NOT NULL,
		[RecommendationSubTypeId] [uniqueidentifier] NOT NULL,
		[RecommendationDescription] [nvarchar](1000) NULL,
		[RecommendationAction] [nvarchar](500) NULL,
		[InstanceId] [varchar](500) NULL,
		[InstanceName] [varchar](100) NULL,
		[AdditionalInfo] [nvarchar](max) NULL,
		[ResourceGroup] [varchar](100) NULL,
		[SubscriptionGuid] [varchar](50) NULL,
		[ConfidenceScore] [real] NOT NULL,
		[Tags] [nvarchar](max) NULL,
		[DetailsUrl] [nvarchar](max) NULL
	)

	ALTER TABLE [dbo].[Recommendations] ADD PRIMARY KEY CLUSTERED 
	(
		[RecommendationId] ASC
	)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ONLINE = OFF) ON [PRIMARY]
END