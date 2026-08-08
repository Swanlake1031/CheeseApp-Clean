# Commerce course full import manifest

Date: 2026-07-31
Source: `/Users/timonayf/degroote-scraper/degroote_commerce_outlines/`
Selection: PDF academic-term content, never filesystem/upload date
Status: production rollout complete through migration 126

## Scope

The source contains 316 PDFs representing 90 course codes. Eight courses are in batch 1; 79 additional courses are prepared in batches 2–4. Three source codes are explicitly deferred, so the verified catalog total is 87 courses. All imports reuse the existing Courses, professor, private outline, review, ownership, validation, and refresh contracts.

No PDF exceeds the existing 20 MB contract and the largest selected file is under 1.4 MB. Compression would add document risk without meaningful benefit, so source bytes are preserved.

## Deferred source codes

- `COMMERCE 1GR0` — The PDF describes the full 2025–26 academic year; the schema requires one term.
- `COMMERCE 4EL3` — The only supplied PDF is a proposal form with no academic term, not a course outline.
- `COMMERCE 4SY3` — The only supplied PDF is a proposal form with no academic term, not a course outline.

## Selected outlines

### Batch 2 — migration 124

| Course | Title | Selected term | Canonical source file | Course professors |
| --- | --- | --- | --- | --- |
| COMMERCE 2DA3 | Decision Making with Analytics | Fall 2025 | `2DA3/2DA3 - Fall 2025 - C01, C02, C04 - L. Shi.pdf` | Lingling Shi; Zahra Mashayekhi |
| COMMERCE 2GR0 | DeGroote Student Experience and Development II | Winter 2026 | `2GR0/2GR0 - Winter 2026 - C01, C02 - A. Boey.pdf` | Anita Boey |
| COMMERCE 2IN0 | Career Development Course | Winter 2026 | `2IN0/2IN0 - Winter 2026 - Irving (R), Russell (B), Sandher (A), Jacobs (G).pdf` | Rouxanne Irving; Brooke Russell; Amar Sandher; Gabriel Jacobs |
| COMMERCE 2NG3 | Negotiations | Fall 2025 | `2NG3/2NG3 - Fall 2025 - C01, C02, C05 - A. Boey.pdf` | Anita Boey; Rami Alasadi; Carolyn Capretta |
| COMMERCE 2OC3 | Operations Management | Winter 2026 | `2OC3/2OC3 - Winter 2026 - C01, C02, C03 - Y.Zhou.pdf` | Yun Zhou; Zeinab Vosooghi |
| COMMERCE 3AB3 | Intermediate Financial Accounting I | Fall 2025 | `3AB3/3AB3 - Fall 2025 - K. Li _ Y. Kwok.pdf` | Ken Li; Yvonne S. Kwok |
| COMMERCE 3AC3 | Intermediate Financial Accounting II | Winter 2026 | `3AC3/3AC3 - Winter 2026 - J.Jin.pdf` | Justin Y. Jin |
| COMMERCE 3DA3 | Predictive Analytics | Winter 2026 | `3DA3/3DA3 - Winter 2026 - C01 - E. Blasioli.pdf` | Emanuele Blasioli |
| COMMERCE 3FB3 | Securities Analysis | Winter 2026 | `3FB3/3FB3 - Winter 2026 - S. Wang.pdf` | Skylar Wang; Ruohan Jin |
| COMMERCE 3FD3 | Financial Modelling | Winter 2026 | `3FD3/3FD3 - Winter 2026 - Y. Zhao.pdf` | Yingnan Zhao |
| COMMERCE 3FH3 | Alternative Investments and Portfolio Management | Winter 2026 | `3FH3/3FH3 - Winter 2026 - A. Mahmood.pdf` | Adeel Mahmood |
| COMMERCE 3FI3 | Market Trading with Options and Futures | Winter 2026 | `3FI3/3FI3 - Winter 2026 - J. Siam.pdf` | John J. Siam |
| COMMERCE 3FK3 | Intermediate Corporate Finance | Fall 2025 | `3FK3/3FK3 - Fall 2025 - C01 - S. Sarkar.pdf` | Sudipto Sarkar |
| COMMERCE 3FM3 | The History of Finance | Winter 2026 | `3FM3/3FM3 - Winter 2026 - W. Huggins.pdf` | William Huggins |
| COMMERCE 3KA3 | System Analysis and Design | Fall 2025 | `3KA3/3KA3 - Fall 2025 - C01 - A. Montazemi.pdf` | Ali Reza Montazemi |
| COMMERCE 3KD3 | Database Design Management and Applications | Winter 2026 | `3KD3/3KD3 - Winter 2026 - C01, C02, C03 - Y. Yuan.pdf` | Yufei Yuan |
| COMMERCE 3MB3 | Consumer Behaviour | Winter 2026 | `3MB3/3MB3 - Winter 2026 - M. Hupfer.pdf` | Maureen Hupfer |
| COMMERCE 3MC3 | Applied Marketing Management | Winter 2026 | `3MC3/3MC3 - Winter 2026 - C01, C03 - M. Malik.pdf` | Mandeep Malik; Kai Christine Lesage; Marvin Ryder |
| COMMERCE 3MD3 | Introduction to Contemporary Applied Marketing | Winter 2023 | `3MD3/3MD3 - Winter 2023 - C01, C02 - Z. Jawed.pdf` | Zobia Jawed |
| COMMERCE 3SO3 | Management Skills Development | Winter 2023 | `3SO3/3SO3 - Winter 2023 - C01, C02, C03, C04, C05, C06 - C. Capretta.pdf` | Carolyn Capretta; Shraddha Wilfred; Karlene Harry |

### Batch 3 — migration 125

| Course | Title | Selected term | Canonical source file | Course professors |
| --- | --- | --- | --- | --- |
| COMMERCE 4AA3 | Managerial Accounting II | Winter 2026 | `4AA3/4AA3 - Winter 2026 - A. S. Merali.pdf` | A. S. Merali |
| COMMERCE 4AC3 | Advanced Financial Accounting | Winter 2026 | `4AC3/4AC3 - Winter 2026 - Y. Kwok.pdf` | Yvonne S. Kwok |
| COMMERCE 4AF3 | Accounting Theory | Winter 2026 | `4AF3/4AF3 - Winter 2026 - J. Jin.pdf` | Justin Y. Jin |
| COMMERCE 4AK3 | Accounting Information for Decision Making | Winter 2025 | `4AK3/4AK3 - Winter 2025 - G. Rombough.pdf` | Greg Rombough |
| COMMERCE 4BB3 | Recruitment and Selection | Winter 2026 | `4BB3/4BB3 - Winter 2026 - C01 - Y. Yao.pdf` | Yao Yao |
| COMMERCE 4BC3 | Collective Bargaining | Winter 2026 | `4BC3/4BC3 - Winter 2026 - C01 - R. Smale.pdf` | Richard Smale |
| COMMERCE 4BE3 | Strategic Compensation/Reward Systems | Fall 2025 | `4BE3/4BE3 - Fall 2025 - C01 - Y. Yao.pdf` | Yao Yao |
| COMMERCE 4BF3 | Labour Law and Policy | Winter 2024 | `4BF3/4BF3 - Winter 2024 - C01 - J. Fudge.pdf` | Judy Fudge |
| COMMERCE 4BI3 | Training and Development | Fall 2025 | `4BI3/4BI3 - Fall 2025 - C01 - H. Chen.pdf` | Helen Chen |
| COMMERCE 4BL3 | Occupational Health and Safety Management | Fall 2025 | `4BL3/4BL3 - Fall 2025 - C01 - L. Djelalian-Pepper.pdf` | Lucy Djelalian Pepper |
| COMMERCE 4BM3 | Strategic Human Resource Planning | Winter 2026 | `4BM3/4BM3 - Winter 2026 - C01 - Y. Yao.pdf` | Yao Yao |
| COMMERCE 4BP3 | Principles of Leadership | Fall 2025 | `4BP3/4BP3 - Fall 2025 - C01 - Y. Berson.pdf` | Yair Berson |
| COMMERCE 4CA3 | Managing and Promoting Health and Healthcare Services | Winter 2021 | `4CA3/4CA3 - Winter 2021 - C01 - K. Khaddadine (Harvie).pdf` | Katia Harvie |
| COMMERCE 4DA3 | Modelling and Prescriptive Analytics | Fall 2025 | `4DA3/4DA3 - Fall 2025 - C01 - Z. Vosooghi.pdf` | Zeinab Vosooghi |
| COMMERCE 4FA3 | Applied Corporate Finance | Winter 2026 | `4FA3/4FA3 - Winter 2026 - A. Danielova.pdf` | Anna N. Danielova |
| COMMERCE 4FB3 | Valuation for Finance Professionals | Winter 2026 | `4FB3/4FB3 - Winter 2026 - A. Danielova.pdf` | Anna N. Danielova |
| COMMERCE 4FC3 | Ethics and Professional Practice in Finance | Fall 2025 | `4FC3/4FC3 - Fall 2025 - C01 - S. Bose.pdf` | Sumit Bose |
| COMMERCE 4FD3 | Financial Institutions | Fall 2024 | `4FD3/4FD3 - Fall 2024 - S. Mehmood.pdf` | Sultan M. Awan |
| COMMERCE 4FE3 | Options and Futures | Winter 2025 | `4FE3/4FE3 - Winter 2025 - R. Luo.pdf` | R. Luo |
| COMMERCE 4FF3 | Portfolio Theory and Management | Fall 2024 | `4FF3/4FF3 - Fall 2024 - A. Aziz.pdf` | Andrew Aziz |
| COMMERCE 4FG3 | Financial Theory | Winter 2023 | `4FG3/4FG3 - Winter 2023 - I. Abdool.pdf` | Imran Abdool |
| COMMERCE 4FH3 | Mergers, Acquisitions and Corporate Control | Winter 2026 | `4FH3/4FH3 - Winter 2026 - S. Sarkar.pdf` | Sudipto Sarkar |
| COMMERCE 4FK3 | Financial Statement Analysis | Winter 2025 | `4FK3/4FK3 - Winter 2025 - A. Damley.pdf` | Alicia Damley |
| COMMERCE 4FL3 | Personal Financial Management | Winter 2026 | `4FL3/4FL3 - Winter 2026 - S. Bose.pdf` | Sumit Bose |
| COMMERCE 4FM3 | Personal Financial Planning and Advising | Winter 2026 | `4FM3/4FM3 - Winter 2026 - S. Bose.pdf` | Sumit Bose |
| COMMERCE 4FN3 | Financial Risk Management | Fall 2025 | `4FN3/4FN3 - Fall 2025 - Damley.pdf` | Alicia Damley |
| COMMERCE 4FO3 | Small Business and Entrepreneurial Finance | Fall 2023 | `4FO3/4FO3 - Fall 2023 - W. Ahmad.pdf` | Waquar Ahmad |
| COMMERCE 4FP3 | Personal Finance | Fall 2025 | `4FP3/4FP3 - Fall 2025 - S. Cheung.pdf` | C. Sherman Cheung |
| COMMERCE 4FQ3 | Working Capital Management | Winter 2023 | `4FQ3/4FQ3 - Winter 2023 - S. Sarkar.pdf` | Sudipto Sarkar |
| COMMERCE 4FR3 | Insurance and Risk Management | Fall 2024 | `4FR3/4FR3 - Fall 2024 - S. Bose.pdf` | Sumit Bose |

### Batch 4 — migration 126

| Course | Title | Selected term | Canonical source file | Course professors |
| --- | --- | --- | --- | --- |
| COMMERCE 4FS3 | Pension, Retirement and Estate Planning | Winter 2025 | `4FS3/4FS3 - Winter 2025 - C01 - S. Bose.pdf` | Sumit Bose |
| COMMERCE 4FT3 | Real Estate Finance and Investment | Winter 2026 | `4FT3/4FT3 - Winter 2026 - A. Mahmood.pdf` | Adeel Mahmood |
| COMMERCE 4FU3 | Behavioural Finance: The Psychology of Markets | Fall 2025 | `4FU3/4FU3 - Fall 2025 - C01 - S. Bose.pdf` | Sumit Bose |
| COMMERCE 4FV3 | Venture Capital | Fall 2025 | `4FV3/4FV3 - Fall 2025 - A. Mahmood.pdf` | Adeel Mahmood |
| COMMERCE 4FW3 | Finance for Entrepreneurs | Fall 2025 | `4FW3/4FW3 - Fall 2025 - T. Chamberlain.pdf` | Trevor Chamberlain |
| COMMERCE 4FX3 | Special Topics in Finance | Fall 2024 | `4FX3/4FX3 - Fall 2024 - L. Waverman.pdf` | Leonard Waverman |
| COMMERCE 4KF3 | Project Management | Winter 2026 | `4KF3/4KF3 - Winter 2026 - C01, C02 - N.Wagner.pdf` | Nicole Wagner |
| COMMERCE 4KG3 | Data Mining For Business Analytics | Winter 2025 | `4KG3/4KG3 - Winter 2025 - C01, C02, C03 - K. Wind.pdf` | Keiwan Wind |
| COMMERCE 4KH3 | Strategies for Electronic and Mobile Business | Fall 2025 | `4KH3/4KH3 - Fall 2025 - C01 - A. Montazemi.pdf` | Ali Reza Montazemi |
| COMMERCE 4KI3 | Business Process Management | Fall 2024 | `4KI3/4KI3 - Fall 2024 - C01 - A. Montazemi.pdf` | Ali Reza Montazemi |
| COMMERCE 4MA3 | Advertising and Integrated Marketing Communication | Winter 2026 | `4MA3/4MA3 - Winter 2026 - C. DeVries.pdf` | Christina DeVries |
| COMMERCE 4MC3 | New Product Marketing | Winter 2026 | `4MC3/4MC3 - Winter 2026 - K. C. Lesage.pdf` | Kai Christine Lesage |
| COMMERCE 4ME3 | Sales Management | Winter 2026 | `4ME3/4ME3 - Winter 2026 - M. Malik.pdf` | Mandeep Malik |
| COMMERCE 4MF3 | Retailing Management | Fall 2024 | `4MF3/4MF3 - Fall 2024 - V. Kumar.pdf` | Vijay Kumar |
| COMMERCE 4MG3 | Strategic Philanthropy and Leadership | Fall 2021 | `4MG3/4MG3 - Fall 2021 - C01 - C. Siklosi, L. Fergusson.pdf` | Lynn Fergusson; Kate Siklosi |
| COMMERCE 4OB3 | Analysis of Production/Operations Problems | Fall 2024 | `4OB3/4OB3 - Fall 2024 - C01 - P. Abad.pdf` | Prakash Abad |
| COMMERCE 4OD3 | Purchasing and Supply Management | Winter 2026 | `4OD3/4OD3 - Winter 2026 - C01 - K. Huang.pdf` | Kai Huang |
| COMMERCE 4OI3 | Supply Chain Management | Fall 2025 | `4OI3/4OI3 - Fall 2025 - C01 - K. Huang.pdf` | Kai Huang |
| COMMERCE 4PA3 | Business Policy: Strategic Management | Winter 2026 | `4PA3/4PA3 - Winter 2026 - R. Cossa, G. Huang, A. Ali.pdf` | Rita Cossa; Grace Huang; Ahzam Ali |
| COMMERCE 4QA3 | Operations Modelling and Analysis | Winter 2026 | `4QA3/4QA3 - Winter 2026 - C01 - A. Foda.pdf` | Ahmed Foda |
| COMMERCE 4SA3 | International Business | Winter 2026 | `4SA3/4SA3 - Winter 2026 - P. Balaji, J. Han, A. Taherizadeh.pdf` | Pavithra Balaji; Jukyeong (Judy) Han; Amir Taherizadeh |
| COMMERCE 4SB3 | Introduction to Canadian Taxation | Fall 2025 | `4SB3/4SB3 - Fall 2025 - E. Bentzen-Bilkvist.pdf` | Eric Bentzen-Bilkvist |
| COMMERCE 4SC3 | Advanced Canadian Taxation | Winter 2026 | `4SC3/4SC3 - Winter 2026 - E. Bentzen Bilkvist.pdf` | Eric Bentzen-Bilkvist |
| COMMERCE 4SD3 | Commercial Law | Winter 2026 | `4SD3/4SD3 - Winter 2026 - K. Ketsetzis.pdf` | Konstantine Ketsetzis |
| COMMERCE 4SE3 | Entrepreneurship | Fall 2025 | `4SE3/4SE3 - Fall 2025 - M. Ryder.pdf` | Marvin Ryder |
| COMMERCE 4SG3 | Sustainability: Corporations and Society | Winter 2026 | `4SG3/4SG3 - Winter 2026 - C. Capretta.pdf` | Carolyn Capretta |
| COMMERCE 4SH3 | Case Analysis and Presentation Skills | Fall 2019 | `4SH3/4SH3 - Fall 2019 - C01 - F. Neville.pdf` | François Neville |
| COMMERCE 4SM3 | Sports Management | Winter 2026 | `4SM3/4SM3 - Winter 2026 - G. Huang.pdf` | Grace Huang |
| COMMERCE 4SX3 | Special Topics in Strategic Management: White Collar Crime | Summer 2020 | `4SX3/4SX3 - Summer 2020 - C01 - D. Sorbara.pdf` | Dom Sorbara |

## Reconciliation notes

- `COMMERCE 1AA3` is corrected forward-only to `Introductory Financial Accounting`.
- `COMMERCE 2AB3` is corrected forward-only to `Managerial Accounting I`.
- Sean O’Brady is added to the existing `COMMERCE 2BC3` Winter 2026 professor set.
- `COMMERCE 3SO3` uses the official code from the source page and filename; its PDF body contains the typo `3S03`.
- `COMMERCE 4FD3` uses Sultan M. Awan because that is the instructor inside the PDF; the CSV filename label is stale.
- `COMMERCE 4FE3` retains `R. Luo`; the official selected PDF does not disclose a full first name.
- `COMMERCE 4PA3` maps the three faculty instructors and does not expose the separately labelled course coordinator as a professor option.

## Rollout contract

1. Complete local reset, seed, pgTAP, app/Test bundle, Worker, hash, and rendered-PDF checks.
2. Compare linked production migration and object state read-only.
3. Upload immutable private Storage objects with overwrite disabled.
4. Apply migrations 123–126 in order.
5. Verify authenticated catalog/outline access and anonymous denial.
6. Do not push GitHub unless separately requested.

## Completed production rollout

The production rollout completed on 2026-07-31 in Storage-first order. Production
was initially at migration 122. All 87 immutable Commerce PDF objects were placed
at their final `<course UUID>/<year>/<term>/<sha256>.pdf` paths in the existing
private `course-outlines` bucket before migrations 123–126 were applied. Seed data
was not run against production.

During the Storage upload, Supabase CLI 2.90.0 initially preserved a local staging
directory name as a remote prefix. No database metadata referenced those staging
objects. The files were moved to their exact final paths, compared against the
checked-in 100-object outline asset set by path and byte size, and only then were
the 76 duplicate staging objects deleted. Final staging-prefix count is zero.

Post-rollout production verification:

- latest migration: `126`;
- Commerce courses: `87`;
- Commerce outlines: `87`;
- Commerce course-professor mappings: `113` across `84` distinct professors;
- duplicate course codes: `0`;
- missing Storage objects referenced by Commerce outlines: `0`;
- Storage size or MIME metadata mismatches: `0`;
- authenticated catalog RPC Commerce rows: `87`;
- `course-outlines` bucket: private, PDF-only, 20 MB object limit;
- final outline Storage objects: `100` total (`13` existing ECON + `87` Commerce);
- temporary Commerce upload-prefix objects: `0`.

Verification completed before rollout:

- local database reset through migrations 001–126 plus seed: passed;
- pgTAP: 24 files and 468 tests passed;
- App target build: passed;
- Test bundle build: passed;
- targeted iOS tests actually executed: 16/16 passed for course discovery,
  course review, and course outline coverage;
- Share Worker check: passed;
- selected PDF render inspection: passed;
- checked-in PDF SHA-256/path and size verification: passed;
- database lint: exited successfully with only pre-existing analyzer findings;
- secrets scan and `git diff --check`: passed before this report update.

GitHub was not pushed as part of this rollout.
