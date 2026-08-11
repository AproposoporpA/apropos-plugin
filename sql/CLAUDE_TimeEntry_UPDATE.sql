/*
    dbo.CLAUDE_TimeEntry_UPDATE  -  revision 2026-08-11

    Adds three parameters so time entries can be corrected programmatically:

      @workDescription        repair a description (43 reconstructed descriptions
                              from 2026-08-07 are blocked without this)
      @eventTypeID            promote an entry to Shift Start (EventTypeID 1) so a
                              day renders in the Apropos UI. Eric has 17 blank days
                              from 2026-07-26 through 2026-08-11 that need this.
      @integrationTimeEntryID Intervals import writeback (the July reconciliation
                              blocker)

    Notes
      - The proc still refuses rows that are already imported or approved, so the
        writeback only works where IntegrationTimeEntryID IS NULL. That is the case
        being unblocked here.
      - @eventTypeID is validated against dbo.TimeTracking_EventType. Confirm that
        ID 1 is Shift Start before promoting days.
      - @workDescription is nvarchar(500) to match the column. The downstream
        Intervals import truncates at 255.
      - Everything else is unchanged from the current proc.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[CLAUDE_TimeEntry_UPDATE]
    @timeEntryID              numeric(18,0),
    @integrationTaskDisplayID numeric(18,0) = NULL,   -- Intervals # (proc resolves to internal TaskID)
    @workTypeID               numeric(18,0) = NULL,
    @workDescription          nvarchar(500) = NULL,   -- NEW: correct a description
    @eventTypeID              numeric(18,0) = NULL,   -- NEW: e.g. 1 = Shift Start, opens the day in the UI
    @integrationTimeEntryID   numeric(18,0) = NULL,   -- NEW: Intervals import writeback
    @recomputeMinimums        bit           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @msg nvarchar(300);

    -- 1. Entry must exist
    IF NOT EXISTS (SELECT 1 FROM dbo.TimeTracking WHERE ID = @timeEntryID)
    BEGIN
        SET @msg = CONCAT('TimeEntry ', @timeEntryID, ' not found.');
        RAISERROR(@msg, 16, 1);
        RETURN;
    END

    -- 2. Never touch an already-imported or approved row.
    --    Stamping IntegrationTimeEntryID on a row that has none yet is the import
    --    writeback itself, which is why that case is still allowed through.
    IF EXISTS (SELECT 1 FROM dbo.TimeTracking
               WHERE ID = @timeEntryID
                 AND (IntegrationTimeEntryID IS NOT NULL
                      OR Approved = 1 OR SupervisorApproved = 1))
    BEGIN
        SET @msg = CONCAT('TimeEntry ', @timeEntryID, ' is already imported or approved; not modified.');
        RAISERROR(@msg, 16, 1);
        RETURN;
    END

    -- 3. Validate the new lookups so a bad id fails loudly instead of corrupting the row
    IF @eventTypeID IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.TimeTracking_EventType WHERE ID = @eventTypeID)
    BEGIN
        SET @msg = CONCAT('EventTypeID ', @eventTypeID, ' not found.');
        RAISERROR(@msg, 16, 1);
        RETURN;
    END

    IF @workDescription IS NOT NULL AND LEN(LTRIM(RTRIM(@workDescription))) = 0
    BEGIN
        RAISERROR('@workDescription cannot be blank.', 16, 1);
        RETURN;
    END

    -- 4. Resolve Intervals display id -> internal task + its scope
    DECLARE @taskID         numeric(18,0) = NULL,
            @projectID      numeric(18,0) = NULL,
            @initiativeID   numeric(18,0) = NULL,
            @organizationID numeric(18,0) = NULL;

    IF @integrationTaskDisplayID IS NOT NULL
    BEGIN
        SELECT @taskID         = ID,
               @projectID      = ProjectID,
               @initiativeID   = InitiativeID,
               @organizationID = OrganizationID
        FROM dbo.Task
        WHERE IntegrationTaskDisplayID = @integrationTaskDisplayID;

        IF @taskID IS NULL
        BEGIN
            SET @msg = CONCAT('No task found for Intervals id ', @integrationTaskDisplayID, '.');
            RAISERROR(@msg, 16, 1);
            RETURN;
        END
    END

    -- 5. Apply only the supplied fields; align scope to the task; backfill minimums
    UPDATE dbo.TimeTracking
    SET TaskID         = COALESCE(@taskID, TaskID),
        ProjectID      = CASE WHEN @taskID IS NOT NULL THEN @projectID      ELSE ProjectID      END,
        InitiativeID   = CASE WHEN @taskID IS NOT NULL THEN @initiativeID   ELSE InitiativeID   END,
        OrganizationID = CASE WHEN @taskID IS NOT NULL THEN @organizationID ELSE OrganizationID END,
        WorkTypeID     = COALESCE(@workTypeID, WorkTypeID),
        WorkDescription = COALESCE(@workDescription, WorkDescription),
        EventTypeID     = COALESCE(@eventTypeID, EventTypeID),
        IntegrationTimeEntryID = COALESCE(@integrationTimeEntryID, IntegrationTimeEntryID),
        DurationWithMinimums = CASE
            WHEN @recomputeMinimums = 1 AND DurationWithMinimums IS NULL
                THEN CAST(CASE WHEN Duration <= 0 THEN 0.25
                               ELSE CEILING(Duration / 0.25) * 0.25 END AS decimal(9,4))
            ELSE DurationWithMinimums END,
        ModifiedOn = GETUTCDATE()
    WHERE ID = @timeEntryID;

    -- 6. Return the corrected row
    SELECT ID, StartTime, ProjectID, TaskID, WorkTypeID, EventTypeID,
           WorkDescription, IntegrationTimeEntryID, Duration, DurationWithMinimums
    FROM dbo.TimeTracking
    WHERE ID = @timeEntryID;
END
GO

GRANT EXECUTE ON [dbo].[CLAUDE_TimeEntry_UPDATE] TO [claudeaproposreadonly];
GO


/* -------------------------------------------------------------------------
   Usage examples

   Repair a description:
     EXEC dbo.CLAUDE_TimeEntry_UPDATE
          @timeEntryID = 331234,
          @workDescription = N'Rewrote the WooCommerce plugin feature registry';

   Promote an entry to Shift Start so its day renders in the UI:
     EXEC dbo.CLAUDE_TimeEntry_UPDATE
          @timeEntryID = 331234,
          @eventTypeID = 1;

   Intervals import writeback:
     EXEC dbo.CLAUDE_TimeEntry_UPDATE
          @timeEntryID = 331234,
          @integrationTimeEntryID = 987654;

   Find the first entry of each blank Pacific day for a person (candidates to
   promote to Shift Start). ShiftStarts = 0 means the day is blank in the UI:

     SELECT CAST(dbo.ConvertUtcToPacific(StartTime) AS date) AS PacDay,
            SUM(CASE WHEN EventTypeID = 1 THEN 1 ELSE 0 END) AS ShiftStarts,
            COUNT(*) AS Rows,
            MIN(ID) AS FirstEntryID
     FROM dbo.TimeTracking
     WHERE ResourceID = 321
     GROUP BY CAST(dbo.ConvertUtcToPacific(StartTime) AS date)
     HAVING SUM(CASE WHEN EventTypeID = 1 THEN 1 ELSE 0 END) = 0
     ORDER BY PacDay;

   Note MIN(ID) is not necessarily the earliest StartTime. Confirm the row you
   promote is actually the day's first entry by StartTime before running it.
   ------------------------------------------------------------------------- */
