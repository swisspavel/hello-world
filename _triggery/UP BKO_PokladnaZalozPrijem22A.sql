USE [HeliosSCS001]
GO

/* info: Vytvo�en� definice ulo�en� procedury BKO_PokladnaZalozPrijem
(pou��van� pro p�enos v�dajov�ho PD do p��jmov�ho PD na HPS) */

SET NOCOUNT ON;
GO

-- pust�me p��padnou d��v�j�� definici ulo�en� procedury
IF OBJECT_ID('[dbo].BKO_PokladnaZalozPrijem', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].BKO_PokladnaZalozPrijem;
GO

-- deklarujeme ulo�enou proceduru znovu
CREATE PROCEDURE [dbo].BKO_PokladnaZalozPrijem
	@chvnCilovaRadaDokladu		NVARCHAR(3),			-- c�lov� �ada doklad� (c�lov� pokladna)
	@intID						INTEGER					-- ID v�choz�ho z�znamu (v�dajov�ho PD)
AS

    -- pseudo-konstanty
	DECLARE @inyFIXVydajovyPD   TINYINT = 16;			-- v�dajov� pokladn� doklad
	DECLARE @inyFIXPrijmovyPD	TINYINT = 17;			-- p��jmov� pokladn� doklad
	DECLARE @inyFIXBezRozlisDD  TINYINT = 0;			-- zp�sob ��slov�n� bez rozli�en� DD
	DECLARE @inyFIXRozliseniDD  TINYINT = 1;			-- zp�sob ��slov�n� podle DD
	DECLARE @intFIXKontaceVyde  INTEGER = 700004;		-- po�adovan� kontace v�dajov�ho dokladu
	DECLARE @intFIXKontacePrij  INTEGER = 710004;		-- po�adovan� kontace p��jmov�ho dokladu

	-- prom�nn�
	DECLARE @inyTypDokladu		TINYINT;				-- zdrojov� typ dokladu
	DECLARE @chvnErrMsg			NVARCHAR(200);			-- text chybov�ho hl�en�
	DECLARE @intIDDruhPokl      INTEGER = 0;			-- ID z�znamu druhu pokladny
	DECLARE @chvnMenaZdrojova	NVARCHAR(3);			-- m�na zdrojov� pokladny
	DECLARE @chvnMenaCilova		NVARCHAR(3);			-- m�na c�lov� pokladny
	DECLARE @intNovePoradi		INTEGER;				-- po�adov� ��slo pro nov� vytv��en� doklad
	DECLARE @intObdobi			INTEGER;				-- obdob� dokladu
	DECLARE @chvnZdrojovaRada   NVARCHAR(3);			-- zdrojov� �ada doklad� (zdrojov� pokladna)
	DECLARE @inyZpusobCislovani TINYINT;				-- zp�sob ��slov�n� (0 = bez rozli�en� druhu dokladu, 1 = podle druhu dokladu)
	DECLARE @intStartPrijem     INTEGER;				-- po��te�n� ��slo p��jmov�ch doklad�
	DECLARE @intKontace			INTEGER;				-- kontace v�choz�ho dokladu

	-- vyt�hneme typ dokladu zpracov�van�ho pokladn�ho dokladu,
	-- (16 = v�daj z pokladny, 17 = p��jem do pokladny)
	-- jeho �adu doklad�, obdob�
	SELECT	@inyTypDokladu = Pokl.TypDokladu, 
			@chvnZdrojovaRada = Pokl.RadaDokladuPokl,
			@intObdobi = Pokl.Obdobi,
			@intKontace = Pokl.UKod
	FROM dbo.TabPokladna Pokl
	WHERE Pokl.ID = @intID;

	IF ( @inyTypDokladu = @inyFIXVydajovyPD )
	BEGIN
		-- m�me v�dajov� doklad -> m��eme tvo�it p��jem

		-- ozna�en� c�lov� pokladny mohlo b�t zad�no i z kl�vesnice, tak�e ov���me
		-- jestli je smyslupln� a ve shodn� m�n� jako pokladna v�choz�
		SELECT	@intIDDruhPokl = Druh.ID, 
				@chvnMenaCilova = Druh.Mena
		FROM dbo.TabDruhPokladen Druh
		WHERE Druh.Cislo = @chvnCilovaRadaDokladu;

		IF ( @intIDDruhPokl IS NULL ) OR ( @intIDDruhPokl = 0 )
			-- c�lov� pokladna nenalezena
			SET @chvnErrMsg = N'Ur�en� c�lov� pokladna nebyla nalezena.';
		ELSE
		BEGIN
			-- c�lov� pokladna nalezena -> testujeme shodu m�n
			SELECT @chvnMenaZdrojova = Druh.Mena
			FROM dbo.TabPokladna Pokl
			INNER JOIN dbo.TabDruhPokladen Druh ON Druh.Cislo = Pokl.RadaDokladuPokl 
			WHERE Pokl.ID = @intID;

			IF @chvnMenaCilova = @chvnMenaZdrojova
			BEGIN
				-- shoda v m�n�ch -> pokra�ujeme

				IF @chvnZdrojovaRada = @chvnCilovaRadaDokladu
					-- zdrojov� i c�lov� pokladna jsou shodn� -> nelze
					SET @chvnErrMsg = N'C�lov� pokladna mus� b�t jin� ne� pokladna zdrojov�.';
				
				ELSE
				BEGIN
					-- zdrojov� i c�lov� pokladna jsou r�zn� -> pokra�ujeme

					IF ( @intKontace IS NULL ) OR ( @intKontace <> @intFIXKontaceVyde )
						-- kontace na zdrojov�m dokladu nem� po�adovanou hodnotu -> nelze
						SET @chvnErrMsg = N'��etn� k�d v�choz�ho dokladu mus� b�t ' + CAST( @intFIXKontaceVyde AS NVARCHAR(6) ) + '.';

					ELSE
					BEGIN
						-- kontace na zdrojov�m dokladu je v po��dku -> pokra�ujeme

						-- vyzvedneme charakteristiky ��slov�n� doklad�
						SELECT 	@inyZpusobCislovani = DefP.ZpusobCislovani,
								@intStartPrijem = DefP.StartPrijem
						FROM dbo.TabDruhPoDef DefP
						WHERE DefP.IdDruhPo = @intIDDruhPokl
						AND DefP.IdObdobi = @intObdobi
						AND DefP.Blokovano = 0;

						-- pot�ebujeme po�adov� ��slo pro c�lov� doklad
						-- podle zp�sobu ��slov�n� hled�me maximum p�es v�echny doklady (pro zp�sob ��slov�n� 0 - bez rozli�en� DD)
						-- nebo maximum p�es p��jmov� pokladn� doklady (pro zp�sob 1 - podle DD)
						SELECT @intNovePoradi = MAX( Pokl.PoradoveCislo )
						FROM dbo.TabPokladna Pokl
						WHERE Pokl.Obdobi = @intObdobi
						AND Pokl.RadaDokladuPokl = @chvnCilovaRadaDokladu
						AND Pokl.TypDokladu = CASE WHEN @inyZpusobCislovani = @inyFIXBezRozlisDD THEN Pokl.TypDokladu ELSE @inyFIXPrijmovyPD END;

						IF @intNovePoradi IS NULL
							-- pokud ��dn� doklad zat�m nem�me, za�neme ��slovat podle nastaven�
							SET @intNovePoradi = @intStartPrijem
						ELSE
							-- n�jak� doklady m�me -> bereme dal�� ��slo v po�ad�
							SET @intNovePoradi = @intNovePoradi + 1;

						-- vkl�d�me nov� p��jmov� doklad
						INSERT INTO dbo.TabPokladna ( /* 01 */ [TypDokladu], [StavDokladu], [PoradoveCislo], [RadaDokladuPokl], [IDPomTxt],
													  /* 02 */ [Popis], [Poznamka], [Prilohy], [Obdobi], [IdObdobiStavu],
													  /* 03 */ [DatPorizeno], [DatPripad], [DUZP], [DatUctovani], [CisloOrg],
													  /* 04 */ [DIC], [CisloZam], [KontaktOsoba], [ParovaciZnak], [ZalohovyDoklad],
													  /* 05 */ [Ukod], [IDSklad], [CisloZakazky], [CisloNakladovyOkruh], [IdVozidlo],
													  /* 06 */ [DatPorizeni], [Autor], [DatZmeny], [Zmenil], [Mena],
													  /* 07 */ [CastkaMena], [DatumKurz], [Kurz], [JednotkaMeny], [KurzEuro],
													  /* 08 */ [RucniZadaniKurzu], [IdPrijmyVydaje], [SamoVyDICDPH], [IdDanovyRezim], [IdDanovyKlic1],
													  /* 09 */ [IdDanovyKlic2], [IdDanovyKlic3], [IdDanovyKlic4], [VcetneDPH1CM], [VcetneDPH2CM],
													  /* 10 */ [VcetneDPH3CM], [VcetneDPH4CM], [OstatniCM], [DatumKurzDoklad], [KurzDoklad],
													  /* 11 */ [MnozstviDoklad], [KurzEuroDoklad], [ZalohaCM], [DatumKurzZaloha], [KurzZaloha],
													  /* 12 */ [MnozstviZaloha], [KurzEuroZaloha], [SazbaDPH1], [SazbaDPH2], [SazbaDPH3],
													  /* 13 */ [SazbaDPH4], [ZakladDPH1], [ZakladDPH2], [ZakladDPH3], [ZakladDPH4],
													  /* 14 */ [CastkaDPH1], [CastkaDPH2], [CastkaDPH3], [CastkaDPH4], [CelkemDPH1],
													  /* 15 */ [CelkemDPH2], [CelkemDPH3], [CelkemDPH4], [Ostatni], [Uhrada],
													  /* 16 */ [Zaloha], [TypPolozek], [ZpusobPrepoctu], [VerzePokladny], [OrganizaceTransakce],
													  /* 17 */ [BlokovaniEditoru], [KumVydaj], [StavPokladny], [StavPokladnyCM], [StavPokladnyCM01],
													  /* 18 */ [StavPokladnyCM02], [StavPokladnyCM03], [StavPokladnyCM04], [StavPokladnyCM05], [StavPokladnyCM06],
													  /* 19 */ [StavPokladnyCM07], [StavPokladnyCM08], [StavPokladnyCM09], [StavPokladnyCM10], [StavPokladnyCM11],
													  /* 20 */ [StavPokladnyCM12], [StavPokladnyCM13], [StavPokladnyCM14], [StavPokladnyCM15], [StavPokladnyCM16],
													  /* 21 */ [StavPokladnyCM17], [StavPokladnyCM18], [StavPokladnyCM19], [StavPokladnyCM20], [Zustatek],
													  /* 22 */ [ZustatekCM], [ZustatekCM01], [ZustatekCM02], [ZustatekCM03], [ZustatekCM04],
													  /* 23 */ [ZustatekCM05], [ZustatekCM06], [ZustatekCM07], [ZustatekCM08], [ZustatekCM09],
													  /* 24 */ [ZustatekCM10], [ZustatekCM11], [ZustatekCM12], [ZustatekCM13], [ZustatekCM14],
													  /* 25 */ [ZustatekCM15], [ZustatekCM16], [ZustatekCM17], [ZustatekCM18], [ZustatekCM19],
													  /* 26 */ [ZustatekCM20], [IDJCDFa], [NavaznyDoklad], [PoziceZaokrDPH], [HraniceZaokrDPH],
													  /* 27 */ [KoeficientProDPH], [ZaokrPoklDokNa50], [ZaokrUhrady], [KHDPHDoLimitu], [PlneniDoLimitu],
													  /* 28 */ [DodFakKV], [StavEET], [EETStorno]
													)
						SELECT	/* 01 */ @inyFIXPrijmovyPD, [StavDokladu], @intNovePoradi, @chvnCilovaRadaDokladu, [IDPomTxt],
								/* 02 */ [Popis], [Poznamka], [Prilohy], [Obdobi], [IdObdobiStavu],
								/* 03 */ [DatPorizeno], [DatPripad], [DUZP], NULL, [CisloOrg],
								/* 04 */ [DIC], [CisloZam], [KontaktOsoba], [ParovaciZnak], [ZalohovyDoklad],
								/* 05 */ @intFIXKontacePrij, [IDSklad], [CisloZakazky], [CisloNakladovyOkruh], [IdVozidlo],
								/* 06 */ GETDATE(), SUSER_SNAME(), NULL, NULL, [Mena],
								/* 07 */ [CastkaMena], [DatumKurz], [Kurz], [JednotkaMeny], [KurzEuro],
								/* 08 */ [RucniZadaniKurzu], [IdPrijmyVydaje], [SamoVyDICDPH], [IdDanovyRezim], [IdDanovyKlic1],
								/* 09 */ [IdDanovyKlic2], [IdDanovyKlic3], [IdDanovyKlic4], [VcetneDPH1CM], [VcetneDPH2CM],
								/* 10 */ [VcetneDPH3CM], [VcetneDPH4CM], [OstatniCM], [DatumKurzDoklad], [KurzDoklad],
								/* 11 */ [MnozstviDoklad], [KurzEuroDoklad], [ZalohaCM], [DatumKurzZaloha], [KurzZaloha],
								/* 12 */ [MnozstviZaloha], [KurzEuroZaloha], [SazbaDPH1], [SazbaDPH2], [SazbaDPH3],
								/* 13 */ [SazbaDPH4], [ZakladDPH1], [ZakladDPH2], [ZakladDPH3], [ZakladDPH4],
								/* 14 */ [CastkaDPH1], [CastkaDPH2], [CastkaDPH3], [CastkaDPH4], [CelkemDPH1],
								/* 15 */ [CelkemDPH2], [CelkemDPH3], [CelkemDPH4], [Ostatni], [Uhrada],
								/* 16 */ [Zaloha], [TypPolozek], [ZpusobPrepoctu], [VerzePokladny], [OrganizaceTransakce],
								/* 17 */ NULL, [KumVydaj], [StavPokladny], [StavPokladnyCM], [StavPokladnyCM01],
								/* 18 */ [StavPokladnyCM02], [StavPokladnyCM03], [StavPokladnyCM04], [StavPokladnyCM05], [StavPokladnyCM06],
								/* 19 */ [StavPokladnyCM07], [StavPokladnyCM08], [StavPokladnyCM09], [StavPokladnyCM10], [StavPokladnyCM11],
								/* 20 */ [StavPokladnyCM12], [StavPokladnyCM13], [StavPokladnyCM14], [StavPokladnyCM15], [StavPokladnyCM16],
								/* 21 */ [StavPokladnyCM17], [StavPokladnyCM18], [StavPokladnyCM19], [StavPokladnyCM20], [Zustatek],
								/* 22 */ [ZustatekCM], [ZustatekCM01], [ZustatekCM02], [ZustatekCM03], [ZustatekCM04],
								/* 23 */ [ZustatekCM05], [ZustatekCM06], [ZustatekCM07], [ZustatekCM08], [ZustatekCM09],
								/* 24 */ [ZustatekCM10], [ZustatekCM11], [ZustatekCM12], [ZustatekCM13], [ZustatekCM14],
								/* 25 */ [ZustatekCM15], [ZustatekCM16], [ZustatekCM17], [ZustatekCM18], [ZustatekCM19],
								/* 26 */ [ZustatekCM20], [IDJCDFa], [NavaznyDoklad], [PoziceZaokrDPH], [HraniceZaokrDPH],
								/* 27 */ [KoeficientProDPH], [ZaokrPoklDokNa50], [ZaokrUhrady], [KHDPHDoLimitu], [PlneniDoLimitu],
								/* 28 */ [DodFakKV], 2, NULL
						FROM dbo.TabPokladna
						WHERE ID = @intID;

					END;

				END;

			END
			ELSE
				-- neshoda v m�n�ch -> chyba
				SET @chvnErrMsg = N'C�lov� pokladna je v jin� m�n� ne� pokladna zdrojov�.';
		END;
	   
	END
	ELSE
		-- nem�me v�dajov� doklad -> chyba
		SET @chvnErrMsg = N'Akce je ur�ena pouze pro v�dajov� pokladn� doklady.';

	IF @chvnErrMsg <> ''
		RAISERROR( @chvnErrMsg, 16, 1 );
GO