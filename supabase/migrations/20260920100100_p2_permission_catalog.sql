-- P2 (Step 15 §6): permission catalog and role templates (Step 06 §2-§4).
-- Reference data, safe for production. Permissions are the unit of evaluation; roles are editable
-- templates (Step 06 §2). OWNER implicitly holds every catalogued permission (see
-- app_authz.has_permission), so later phases only need to add new permission keys here.
-- Audit triggers are paused while the version-controlled reference rows are inserted.

alter table public.roles disable trigger tg_audit;
alter table public.role_permissions disable trigger tg_audit;

-- ------------------------------------------------------------ permission catalog
insert into public.permissions (key, module, action, description)
select v.module || '.' || v.action, v.module, v.action, v.description
from (values
  ('dashboard', 'view', 'View the dashboard of an Entity'),

  ('invoices', 'view', 'View invoices and receipts'),
  ('invoices', 'create', 'Create draft invoices'),
  ('invoices', 'edit', 'Edit draft invoices'),
  ('invoices', 'submit', 'Submit an invoice for approval'),
  ('invoices', 'approve', 'Approve or reject invoices'),
  ('invoices', 'issue', 'Issue an invoice (assigns its number)'),
  ('invoices', 'confirm_payment', 'Confirm a customer payment'),
  ('invoices', 'void', 'Cancel or void an invoice'),
  ('invoices', 'export', 'Export invoice data in bulk'),
  ('invoices', 'archive', 'Delete drafts or archive invoices'),
  ('invoices', 'regenerate_link', 'Regenerate the public invoice link'),

  ('bills', 'view', 'View bills and direct expenses'),
  ('bills', 'create', 'Create draft bills'),
  ('bills', 'edit', 'Edit draft bills'),
  ('bills', 'submit', 'Submit a bill for approval'),
  ('bills', 'approve', 'Approve or reject bills'),
  ('bills', 'pay', 'Pay a bill'),
  ('bills', 'void', 'Cancel or void a bill'),
  ('bills', 'export', 'Export bill data in bulk'),
  ('bills', 'archive', 'Delete drafts or archive bills'),

  ('money', 'view', 'View financial accounts, payments and transfers'),
  ('money', 'create', 'Record payments and money movements'),
  ('money', 'edit', 'Edit draft money movements'),
  ('money', 'transfer_create', 'Create a transfer between accounts'),
  ('money', 'transfer_approve', 'Approve a sensitive transfer'),
  ('money', 'reconcile', 'Reconcile bank and cash accounts'),
  ('money', 'adjust', 'Post a reconciliation adjustment'),
  ('money', 'export', 'Export money data in bulk'),
  ('money', 'archive', 'Archive financial accounts and channels'),
  ('money', 'view_sensitive', 'See unmasked bank account numbers'),

  ('refunds', 'view', 'View refunds'),
  ('refunds', 'create', 'Create a refund'),
  ('refunds', 'confirm', 'Confirm a refund'),

  ('contacts', 'view', 'View customers and vendors'),
  ('contacts', 'create', 'Create contacts'),
  ('contacts', 'edit', 'Edit contacts'),
  ('contacts', 'archive', 'Delete or archive contacts'),
  ('contacts', 'export', 'Export contacts in bulk'),
  ('contacts', 'view_sensitive', 'See contact tax identifiers'),

  ('products', 'view', 'View products and services'),
  ('products', 'create', 'Create products and services'),
  ('products', 'edit', 'Edit products and services'),
  ('products', 'archive', 'Delete or archive products and services'),

  ('categories', 'manage', 'Create, edit and delete categories'),

  ('accounting', 'view', 'View the ledger, journals and periods'),
  ('accounting', 'journal_create', 'Create manual or adjusting journals'),
  ('accounting', 'journal_approve', 'Approve journals'),
  ('accounting', 'journal_post', 'Post journals'),
  ('accounting', 'protected_manage', 'Manage protected accounts'),
  ('accounting', 'export', 'Export accounting data in bulk'),

  ('periods', 'close', 'Close an accounting period'),
  ('periods', 'reopen', 'Reopen a closed accounting period'),

  ('assets', 'view', 'View fixed assets'),
  ('assets', 'manage', 'Manage fixed assets'),
  ('loans', 'view', 'View loans'),
  ('loans', 'manage', 'Manage loans'),
  ('equity', 'view', 'View equity and owner transactions'),
  ('equity', 'manage', 'Manage equity and owner transactions'),

  ('tax', 'view', 'View tax determinations and the tax ledger'),
  ('tax', 'confirm_facts', 'Confirm tax facts'),
  ('tax', 'override', 'Override a permitted tax determination'),
  ('tax', 'mark_filed', 'Mark tax as paid, filed or reconciled'),
  ('tax', 'manage_rules', 'Manage the tax rule master'),
  ('tax', 'export', 'Export tax data'),

  ('payroll', 'employee_view', 'View employee records'),
  ('payroll', 'employee_edit', 'Edit employee records'),
  ('payroll', 'compensation_view', 'View employee compensation'),
  ('payroll', 'compensation_edit', 'Edit employee compensation'),
  ('payroll', 'run', 'Run payroll'),
  ('payroll', 'approve', 'Approve payroll'),
  ('payroll', 'pay', 'Pay payroll'),
  ('payroll', 'tax_view', 'View employee tax identifiers and payroll tax ledger'),

  ('reports', 'view', 'View reports'),
  ('reports', 'export', 'Export reports'),
  ('reports', 'cross_entity', 'View consolidated cross-Entity analytics (no mutation rights)'),

  ('documents', 'view', 'View documents'),
  ('documents', 'upload', 'Upload documents'),
  ('documents', 'export', 'Export documents in bulk'),

  ('users', 'view', 'View users, memberships and roles of an Entity'),
  ('users', 'invite', 'Invite users'),
  ('users', 'disable', 'Disable users and memberships'),
  ('users', 'assign_entity', 'Give a user access to an Entity'),
  ('users', 'assign_role', 'Assign roles'),
  ('users', 'change_permissions', 'Change individual permissions'),
  ('users', 'revoke_session', 'Revoke user sessions'),

  ('security', 'view', 'View security events and trusted devices'),
  ('security', 'manage', 'Change security settings'),

  ('backup', 'create', 'Create backups'),
  ('backup', 'restore', 'Restore backups'),

  ('audit', 'view', 'View the audit log'),
  ('audit', 'export', 'Export the audit log'),

  ('settings', 'view', 'View Entity settings, numbering and approval rules'),
  ('settings', 'manage', 'Change Entity settings and approval rules'),
  ('settings', 'numbering', 'Change document numbering'),

  ('coa', 'manage', 'Manage the chart of accounts'),

  ('system', 'import', 'Run data imports'),
  ('system', 'rollback_import', 'Roll back a data import'),
  ('system', 'manage_templates', 'Manage document templates'),
  ('system', 'entity_config', 'Configure the Entity')
) as v(module, action, description);

-- ------------------------------------------------------------ role templates
insert into public.roles (role_key, name, description, is_system) values
  ('owner', 'Owner / Super Admin', 'Full control of every authorized Entity. Initial user only.', true),
  ('finance_admin', 'Finance Admin', 'Day-to-day finance administration without ownership or security takeover.', true),
  ('finance_staff', 'Finance Staff', 'Routine sales, purchases, payments and documents within granted limits.', true),
  ('approver', 'Approver', 'Reviews and approves configured transactions without broad edit rights.', true),
  ('accountant', 'Accountant', 'Accounting, reconciliation, closing support, journals and financial reports.', true),
  ('tax', 'Tax', 'Tax review, tax ledger, tax reports and compliance evidence.', true),
  ('payroll', 'Payroll', 'Employee and payroll access without unrelated finance or private data.', true),
  ('viewer_auditor', 'Viewer / Auditor', 'Read-only access to specifically granted modules and reports.', true);

-- Templates follow the Step 06 §3 matrix. Anything not listed is deliberately withheld and can only be
-- added per membership through an explicit, audited grant.
insert into public.role_permissions (role_id, permission_key)
select r.id, k
from public.roles r
join (values
  ('finance_admin', array[
    'dashboard.view',
    'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.submit', 'invoices.issue',
    'invoices.confirm_payment', 'invoices.export', 'invoices.archive', 'invoices.regenerate_link',
    'bills.view', 'bills.create', 'bills.edit', 'bills.submit', 'bills.approve', 'bills.pay',
    'bills.export', 'bills.archive',
    'money.view', 'money.create', 'money.edit', 'money.transfer_create', 'money.reconcile', 'money.export',
    'refunds.view',
    'contacts.view', 'contacts.create', 'contacts.edit', 'contacts.archive', 'contacts.export',
    'products.view', 'products.create', 'products.edit', 'products.archive',
    'categories.manage',
    'accounting.view',
    'assets.view', 'assets.manage', 'loans.view', 'loans.manage', 'equity.view', 'equity.manage',
    'tax.view',
    'reports.view', 'reports.export',
    'documents.view', 'documents.upload',
    'settings.view']),
  ('finance_staff', array[
    'dashboard.view',
    'invoices.view', 'invoices.create', 'invoices.edit', 'invoices.submit',
    'bills.view', 'bills.create', 'bills.edit', 'bills.submit',
    'money.view', 'money.create',
    'contacts.view', 'contacts.create', 'contacts.edit',
    'products.view', 'products.create', 'products.edit',
    'assets.view',
    'documents.view', 'documents.upload']),
  ('approver', array[
    'dashboard.view',
    'invoices.view', 'invoices.approve',
    'bills.view', 'bills.approve',
    'money.view', 'money.transfer_approve',
    'refunds.view',
    'accounting.journal_approve']),
  ('accountant', array[
    'dashboard.view',
    'accounting.view', 'accounting.journal_create', 'accounting.journal_approve', 'accounting.journal_post',
    'accounting.export',
    'periods.close',
    'coa.manage',
    'money.view', 'money.reconcile', 'money.adjust',
    'invoices.view', 'bills.view', 'contacts.view', 'products.view',
    'assets.view', 'loans.view', 'equity.view', 'tax.view',
    'reports.view', 'reports.export',
    'documents.view']),
  ('tax', array[
    'dashboard.view',
    'tax.view', 'tax.confirm_facts', 'tax.mark_filed', 'tax.export',
    'invoices.view', 'bills.view', 'accounting.view',
    'reports.view', 'reports.export',
    'documents.view']),
  ('payroll', array[
    'dashboard.view',
    'payroll.employee_view', 'payroll.employee_edit', 'payroll.compensation_view', 'payroll.compensation_edit',
    'payroll.run', 'payroll.approve', 'payroll.pay', 'payroll.tax_view',
    'documents.view']),
  ('viewer_auditor', array[
    'dashboard.view',
    'invoices.view', 'bills.view', 'money.view', 'contacts.view', 'products.view',
    'accounting.view', 'assets.view', 'loans.view', 'equity.view', 'tax.view',
    'reports.view', 'documents.view', 'audit.view'])
) as t(role_key, keys) on t.role_key = r.role_key
cross join lateral unnest(t.keys) as k;

alter table public.roles enable trigger tg_audit;
alter table public.role_permissions enable trigger tg_audit;
