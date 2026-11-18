/* Run these one at a time in SSMS while the dashboard is open.
   A change to the tab you're viewing appears within ~1 second.
   A change to the other tab puts a blue "updated" dot on that tab;
   open it and the changed rows flash. */

-- Project budgets tab (Finance database)
UPDATE LiveDashboardMT_Finance.dbo.Projects
   SET Spent = 52300, Status = 'at_risk', UpdatedAt = SYSUTCDATETIME()
 WHERE Name = N'Badge reader rollout';

-- Task status tab (Operations database)
UPDATE LiveDashboardMT_Ops.dbo.Tasks
   SET Status = 'done', Notes = N'All operators recertified.', UpdatedAt = SYSUTCDATETIME()
 WHERE Name = N'Forklift recertification';

INSERT INTO LiveDashboardMT_Ops.dbo.Tasks (Name, Category, Owner, Location, Priority, Status, DueDate)
VALUES (N'Added from SSMS', N'Quality', N'Morgan Reyes', N'Office', 'High', 'open', '2027-03-01');

DELETE FROM LiveDashboardMT_Ops.dbo.Tasks WHERE Name = N'Added from SSMS';
